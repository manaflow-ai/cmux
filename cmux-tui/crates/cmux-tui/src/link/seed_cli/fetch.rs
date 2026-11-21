//! `cmux link seed fetch --socket PATH LOCAL REMOTE [--adopt]`: the first copy
//! of a Cloud machine's folder on this Mac (Transfer to This Mac of any Cloud
//! chat, not only one this Mac moved there). LOCAL must not exist or be empty;
//! a fetch that fails removes the folder it made, so a retry starts over.
//!
//! - A folder without a repository, or a repository with all its objects (a
//!   copy pushed it): `cmux link sync pull`'s engine with a base that says
//!   nothing was pushed ([`sync_cli::fetch`]): files, the branch and its
//!   commits, and what is staged, as the machine has them.
//! - A partial clone (a seed: `cmux link seed clone`, or Move to Cloud of a
//!   GitHub project): this Mac clones its `origin` (`https://` only, this
//!   Mac's own git credentials, no prompt) without blobs, checks out the seed's
//!   HEAD (`refs/cmux-seed/head` on the machine) on the machine's branch, and
//!   pulls the machine's changes since that commit as `cmux link seed pull`
//!   does (the machine's export, merged into the clean checkout: its commits as
//!   a fast-forward, its staged and working changes).
//!
//! Secrets never come back (`cmux link access`'s secret names, untracked
//! `.env*`), nor ignored files. `--adopt` (the chat moves here) keeps the
//! sync records on both sides, so the move's last pull and a later Bring Back
//! build on this fetch; without it (a copy, the chat stays on the machine)
//! nothing on the machine changes but a seed's export record.
//!
//! `--find-root` takes the machine's repository REMOTE is in (the nearest
//! folder above it with a `.git` folder, never `/` or a home folder itself),
//! else REMOTE: a chat's folder is often a subfolder of its project.
//!
//! Output: one JSON line, `{"ok":true,"mode":"copy"|"git"|"seed","folder":
//! LOCAL,"remote_root":THE_FOLDER_COPIED,...the pull's summary}` (exit 0), or `{"ok":false,"error",
//! "error_code"}` (exit 1): `fetch.no_folder`, `fetch.folder_not_empty`,
//! `fetch.no_remote` (a partial clone without an `https://` origin),
//! `fetch.not_a_seed`, `fetch.clone_failed`, `fetch.base_unreachable` (the
//! seed's HEAD is not on the remote: push it from the machine first),
//! `machine_outdated`, `sync_conflict`, `sync_failed`; with `--find-root`,
//! `fetch.too_broad` (no repository, and the chat's folder is `/`, a top
//! folder or a home folder: it would bring the machine's sign-ins along).

use cmux_process::Command;
use std::path::Path;

use serde_json::{Value, json};

use super::super::access_cli;
use super::super::sync_cli::{self, Back, SeedBase, SeedPulled, fetch::Shape};
use super::pull::keep;

/// The CLI's fetch (module docs): its line and exit code.
pub(super) fn run(
    socket: &Path,
    local: &Path,
    remote: &str,
    adopt: bool,
    find_root: bool,
) -> (Value, i32) {
    let keep_new = |relative: &str| !access_cli::is_secret(relative);
    let found =
        if find_root { sync_cli::fetch::repo_root(socket, remote).ok().flatten() } else { None };
    let remote = found.as_deref().unwrap_or(remote);
    if find_root && sync_cli::fetch::too_broad(remote) {
        let error = format!(
            "{remote} is a home or top folder on the machine; open the chat in a project folder to transfer it"
        );
        return (json!({ "ok": false, "error": error, "error_code": "fetch.too_broad" }), 1);
    }
    let back = match sync_cli::fetch::shape(socket, remote) {
        Ok(Shape::Partial { remote_url }) => partial(socket, local, remote, remote_url, adopt),
        Ok(_) => sync_cli::fetch::fetch(socket, local, remote, adopt, &keep_new),
        Err(error) => Back::Failed { code: "fetch.no_folder".into(), error: format!("{error:#}") },
    };
    match back {
        Back::Done(mut summary) => {
            cmux_json::JsonSet::set(&mut summary, "folder", json!(local.display().to_string()));
            cmux_json::JsonSet::set(&mut summary, "remote_root", json!(remote));
            (summary, 0)
        }
        Back::Conflict(conflicts, reasons) => {
            let error = format!(
                "{} changed while the folder came over ({})",
                conflicts.join(", "),
                reasons.join("; ")
            );
            (
                json!({ "ok": false, "error": error, "error_code": "sync_conflict", "conflicts": conflicts }),
                1,
            )
        }
        Back::Failed { code, error } => {
            (json!({ "ok": false, "error": error, "error_code": code }), 1)
        }
    }
}

fn partial(socket: &Path, local: &Path, remote: &str, url: Option<String>, adopt: bool) -> Back {
    let failed = |code: &str, error: String| Back::Failed { code: code.into(), error };
    let Some(url) = url else {
        return failed(
            "fetch.no_remote",
            "the machine's folder is a partial clone with no https origin to fetch it from".into(),
        );
    };
    let (head, branch) = match sync_cli::fetch::seed_head(socket, remote) {
        Ok(Some(found)) => found,
        Ok(None) => {
            return failed(
                "fetch.not_a_seed",
                "the machine's partial clone has no seed record to start from".into(),
            );
        }
        Err(error) => return failed("sync_failed", format!("{error:#}")),
    };
    let made = match sync_cli::fetch::claim(local) {
        Ok(made) => made,
        Err(error) => return failed("fetch.folder_not_empty", format!("{error:#}")),
    };
    let answer = (|| {
        let git = |args: &[&str]| {
            Command::new("git")
                .arg("-C")
                .arg(local)
                .args(args)
                .env("GIT_TERMINAL_PROMPT", "0")
                .output()
                .map(|out| {
                    (out.status.success(), String::from_utf8_lossy(&out.stderr).trim().to_owned())
                })
                .unwrap_or_else(|error| (false, error.to_string()))
        };
        let (ok, why) =
            git(&["clone", "-q", "--filter=blob:none", "--no-checkout", "--", &url, "."]);
        if !ok {
            return failed("fetch.clone_failed", format!("cannot clone {url}: {why}"));
        }
        if !git(&["cat-file", "-e", &format!("{head}^{{commit}}")]).0
            && !git(&["fetch", "-q", "origin", &head]).0
        {
            return failed(
                "fetch.base_unreachable",
                format!("{head} is not on {url}; push the machine's branch, then transfer again"),
            );
        }
        let checkout = match branch.as_deref().and_then(|name| name.strip_prefix("refs/heads/")) {
            Some(name) => git(&["checkout", "-q", "-B", name, &head]),
            None => git(&["checkout", "-q", "--detach", &head]),
        };
        if !checkout.0 {
            return failed(
                "fetch.clone_failed",
                format!("cannot check out {head}: {}", checkout.1),
            );
        }
        // A fresh clone: no stash ref before the pull, and that is known.
        let base = SeedBase {
            head: head.clone(),
            index: head.clone(),
            work: head.clone(),
            stash: None,
            stash_known: true,
        };
        match sync_cli::seed_pull(socket, local, remote, &base) {
            Ok(SeedPulled::Done(mut summary)) => {
                if adopt {
                    keep(local, remote, None, Some(url.clone()), &summary);
                }
                cmux_json::JsonSet::set(&mut summary, "mode", json!("seed"));
                Back::Done(summary)
            }
            Ok(SeedPulled::Conflict(conflicts, reasons)) => Back::Conflict(conflicts, reasons),
            Err(error) => failed(&sync_cli::seed_pull_failure_code(&error), format!("{error:#}")),
        }
    })();
    if !matches!(answer, Back::Done(_)) && made {
        let _ = std::fs::remove_dir_all(local);
    }
    answer
}
