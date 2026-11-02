//! `git-seed-v1`: puts a project on a cmux Cloud machine without copying it
//! (leo-workspace `design/cloud.md`, "Getting the project onto the
//! machine"). The machine clones the project's GitHub remote at a base
//! commit and applies one small git bundle the Mac uploaded through `fs-v1`
//! with only the local diff: HEAD's unpushed commits, an INDEX commit (the
//! staged tree), a WORK commit (the working tree with untracked files that
//! are not ignored) and the stash.
//!
//! Served exactly where `fs-v1` is (Cloud hosts), with its sandbox: the
//! folder and the bundle must lie under the roots `fs-v1` serves. A clone of
//! a large repository takes minutes, so `git.seed.start` answers at once with
//! a job and the work runs on a thread of its own; `git.seed.status` reads
//! the job. No token comes from the Mac: git uses the machine's own GitHub
//! path, in the order of CloudMachineRepo's `repo` step ([`git`]).
//!
//! `git-seed-export-v1` adds `git.seed.export`, the way back ([`export`]):
//! the machine bundles what changed since a seed (its commits, an INDEX and
//! a WORK commit made exactly as the Mac makes them) for the Mac to fetch
//! and merge. It is a job too; `git.seed.status` reads it.

mod export;
mod git;
mod job;
mod params;
mod place;
mod run;
pub mod secrets;
mod snapshot;
mod worktree;

use std::sync::OnceLock;

use serde_json::{Value, json};

pub use job::GitSeedService;

/// The capability that carries the `git.seed.*` ops.
pub const GIT_SEED_CAPABILITY: &str = "git-seed-v1";

/// The ops of `git-seed-v1`, exactly. The link's remote gate admits these
/// (and [`GIT_SEED_EXPORT_COMMANDS`]) beside the `fs-v1` ops and nothing else.
pub const GIT_SEED_COMMANDS: [&str; 2] = ["git.seed.start", "git.seed.status"];

/// The capability that carries `git.seed.export`. A capability of its own,
/// not a new op of `git-seed-v1`: a machine that advertises only
/// `git-seed-v1` would deny the op at its remote gate, so a Mac asks for this
/// one before it pulls a seed back.
pub const GIT_SEED_EXPORT_CAPABILITY: &str = "git-seed-export-v1";

/// The ops of `git-seed-export-v1`, exactly (its jobs are read with
/// `git.seed.status`).
pub const GIT_SEED_EXPORT_COMMANDS: [&str; 1] = ["git.seed.export"];

static SERVICE: OnceLock<GitSeedService> = OnceLock::new();

/// Test seam, debug builds only: `CMUX_TEST_GIT_SEED_GITHUB=<absolute dir>`
/// makes the daemon's seeds clone `https://github.com/OWNER/NAME.git` from
/// `file://<dir>/OWNER/NAME.git`, with no GitHub path
/// ([`GitSeedService::with_test_github`]). Release builds never read it.
#[cfg(debug_assertions)]
const TEST_GITHUB_VAR: &str = "CMUX_TEST_GIT_SEED_GITHUB";

/// The seed owner, when this daemon serves `fs-v1` (it seeds under the same
/// roots).
#[must_use]
pub fn installed() -> Option<&'static GitSeedService> {
    let fs = crate::fs_ops::installed()?;
    Some(SERVICE.get_or_init(|| {
        #[cfg(debug_assertions)]
        if let Some(dir) = std::env::var_os(TEST_GITHUB_VAR)
            .map(std::path::PathBuf::from)
            .filter(|dir| dir.is_absolute())
        {
            return GitSeedService::with_test_github(fs.roots().clone(), &dir);
        }
        GitSeedService::new(fs.roots().clone())
    }))
}

/// The capabilities to advertise in `identify`, when served.
#[must_use]
pub fn advertised() -> Vec<&'static str> {
    match crate::fs_ops::installed() {
        Some(_) => vec![GIT_SEED_CAPABILITY, GIT_SEED_EXPORT_CAPABILITY],
        None => Vec::new(),
    }
}

/// The `cmd` of `line` when it is one of [`GIT_SEED_COMMANDS`] or
/// [`GIT_SEED_EXPORT_COMMANDS`], exactly.
#[must_use]
pub fn frame_command(line: &str) -> Option<&'static str> {
    let value: Value = serde_json::from_str(line).ok()?;
    let object = value.as_object()?;
    // A frame with `protocol` goes to the resource router, never here.
    if object.contains_key("protocol") {
        return None;
    }
    let cmd = object.get("cmd")?.as_str()?;
    GIT_SEED_COMMANDS.iter().chain(&GIT_SEED_EXPORT_COMMANDS).copied().find(|known| *known == cmd)
}

/// A refused request: its wire code and display text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SeedRefusal {
    pub code: &'static str,
    pub message: String,
}

impl SeedRefusal {
    pub(crate) fn bad_request(message: impl Into<String>) -> Self {
        Self { code: "seed.bad_request", message: message.into() }
    }
}

/// The answer to one `git.seed.*` request line, in the daemon's envelope
/// (`{id, ok, data}` or `{id, ok: false, error, error_code}`). `service` is
/// `None` on a host that is not a Cloud host; `transport_allowed` is the
/// connection's check (the trusted local socket or the link's remote entry).
#[must_use]
pub fn answer_line(service: Option<&GitSeedService>, transport_allowed: bool, line: &str) -> Value {
    let Ok(Value::Object(request)) = serde_json::from_str::<Value>(line) else {
        return envelope(&Value::Null, Err(SeedRefusal::bad_request("not a JSON object")));
    };
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let Some(cmd) = frame_command(line) else {
        return envelope(&id, Err(SeedRefusal::bad_request("unknown git.seed op")));
    };
    if !transport_allowed {
        return envelope(
            &id,
            Err(SeedRefusal {
                code: "seed.permission_denied",
                message: "permission denied".into(),
            }),
        );
    }
    let Some(service) = service else {
        return envelope(
            &id,
            Err(SeedRefusal {
                code: "seed.unavailable",
                message: "git seeding is served only on cmux Cloud hosts (git-seed-v1 is not served here)"
                    .into(),
            }),
        );
    };
    envelope(&id, service.call(cmd, &Value::Object(request)))
}

fn envelope(id: &Value, result: Result<Value, SeedRefusal>) -> Value {
    match result {
        Ok(data) => json!({ "id": id, "ok": true, "data": data }),
        Err(refusal) => json!({
            "id": id,
            "ok": false,
            "error": refusal.message,
            "error_code": refusal.code,
        }),
    }
}

#[cfg(test)]
mod tests;
