//! The person's own GitHub login on a cmux Cloud machine, carried from their Mac ("Use my GitHub
//! login"; Leo, 2026-11-25: "Convienient beats all. Just make good ui for it so people flow.").
//!
//! The Mac app seals the token of the Mac's own `gh` login to this machine's daemon
//! (`git-host-tokens-v1`, `cmux carrier secrets` `use-github-login`), which writes it to
//! `~/.config/cmux/git-hosts/github.com` (0600, one line): the same folder and checks as the
//! person's GitLab token (`gitlab_cli.rs`). It is never in an env file, argv or a log; forgetting
//! it (the machine's settings, `cmux cloud github-login forget`) removes the file.
//!
//! git (`cmux github credential`) and `gh` (the image's shim, `cmux github gh --auto`) use it
//! first, when it reaches the repository: one `gh api repos/OWNER/NAME` with it says whether it
//! can read and push. When it cannot do what the operation needs, the cmux GitHub App's
//! one-repo token is asked as before, and when neither can, the note names both, so the chat
//! says which login to fix instead of GitHub's bare "Repository not found".

use std::ffi::OsString;
use std::io::Read as _;
use std::path::Path;
use std::time::{Duration, Instant};

use zeroize::Zeroizing;

use crate::github_cli::{
    GitOp, Minted, Refused, TokenAsk, credential_get, parse_credential_input, repo_from,
};

/// The host the carried login is for.
pub const HOST: &str = "github.com";
/// How long the reach check may take.
const PROBE_WAIT: Duration = Duration::from_secs(20);
/// The store's `gh`, past the image's shim.
const STORE_GH: &str = "/opt/cmux/current/bin/gh";

/// The carried token under `home`, when there is one that passes the file checks. A file that
/// fails them is a note for stderr (never its content).
pub fn token(home: &Path) -> Result<Option<Zeroizing<String>>, String> {
    let Some(path) = crate::gitlab_cli::token_path(home, HOST) else { return Ok(None) };
    crate::gitlab_cli::read_token(&path).map(|token| token.map(Zeroizing::new))
}

/// What the carried login may do in one repository.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reach {
    /// It can push (GitHub's `permissions.push`).
    Write,
    /// It can read, not push.
    Read,
    /// GitHub answered no such repository for it, or the check failed.
    None,
}

impl Reach {
    /// Whether this covers `op`: a push needs write; a fetch or an unknown operation any reach
    /// (an unknown operation that turns out to be a push is refused by GitHub with its own words).
    pub fn covers(self, op: GitOp) -> bool {
        match op {
            GitOp::Push => self == Self::Write,
            GitOp::Read | GitOp::Unknown => self != Self::None,
        }
    }
}

/// `gh api repos/REPO --jq .permissions.push` with the carried token, as a [`Reach`].
pub fn probe(gh: &OsString, token: &str, repo: &str) -> Reach {
    let Ok(mut child) = std::process::Command::new(gh)
        .args(["api", &format!("repos/{repo}"), "--jq", ".permissions.push"])
        .env("GH_TOKEN", token)
        .env("GH_HOST", HOST)
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env_remove("GITHUB_TOKEN")
        .env_remove("GH_ENTERPRISE_TOKEN")
        .env_remove("GITHUB_ENTERPRISE_TOKEN")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
    else {
        return Reach::None;
    };
    let started = Instant::now();
    let ok = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.success(),
            Err(_) => break false,
            Ok(None) if started.elapsed() > PROBE_WAIT => {
                let _ = child.kill();
                let _ = child.wait();
                break false;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
        }
    };
    let mut out = String::new();
    if let Some(stdout) = child.stdout.take() {
        let _ = stdout.take(64).read_to_string(&mut out);
    }
    reach_of(ok, &out)
}

/// The probe's exit and output as a [`Reach`].
pub fn reach_of(ok: bool, out: &str) -> Reach {
    match (ok, out.trim()) {
        (true, "true") => Reach::Write,
        (true, _) => Reach::Read,
        (false, _) => Reach::None,
    }
}

/// The gh the probe runs: the store's, past the shim, else `gh` on PATH.
pub fn probe_gh() -> OsString {
    if Path::new(STORE_GH).is_file() { STORE_GH.into() } else { "gh".into() }
}

/// What the carried login could not do, as the note's first sentence.
fn cannot(reach: Reach, repo: &str) -> String {
    match reach {
        Reach::Read => format!("your GitHub login can read {repo} but not push to it."),
        Reach::Write | Reach::None => format!("your GitHub login can't reach {repo}."),
    }
}

/// `credential get` with the carried login first. `own` is the carried token and its probe;
/// `ask` mints the cmux GitHub App's token, as [`credential_get`] does.
pub fn credential_get_own_first(
    input: &str,
    op: GitOp,
    workflows: bool,
    own: Option<(&str, &mut dyn FnMut(&str) -> Reach)>,
    ask: &mut dyn FnMut(&TokenAsk) -> Result<Minted, Refused>,
) -> (String, Option<String>) {
    let desc = parse_credential_input(input);
    let field = |k: &str| desc.get(k).and_then(serde_json::Value::as_str).unwrap_or("");
    let repo = (field("protocol") == "https" && field("host").eq_ignore_ascii_case(HOST))
        .then(|| repo_from(field("path")))
        .flatten();
    let (Some((token, probe)), Some(repo)) = (own, repo) else {
        return credential_get(input, op, workflows, ask);
    };
    let reach = probe(&repo);
    if reach.covers(op) {
        return (format!("username=x-access-token\npassword={token}\n"), None);
    }
    let (out, note) = credential_get(input, op, workflows, ask);
    let first = cannot(reach, &repo);
    if out.is_empty() {
        let rest = note.map_or_else(String::new, |note| format!(" The cmux GitHub App: {note}"));
        return (out, Some(format!("{first}{rest}")));
    }
    (out, Some(format!("{first} Using the cmux GitHub App's token for it.")))
}

#[cfg(test)]
#[path = "github_own_login_tests.rs"]
mod tests;
