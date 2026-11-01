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

mod git;
mod job;
mod params;
mod place;
mod run;
mod worktree;

use std::sync::OnceLock;

use serde_json::{Value, json};

pub use job::GitSeedService;

/// The capability that carries the `git.seed.*` ops.
pub const GIT_SEED_CAPABILITY: &str = "git-seed-v1";

/// The ops of `git-seed-v1`, exactly. The link's remote gate admits these
/// beside the `fs-v1` ops and nothing else.
pub const GIT_SEED_COMMANDS: [&str; 2] = ["git.seed.start", "git.seed.status"];

static SERVICE: OnceLock<GitSeedService> = OnceLock::new();

/// The seed owner, when this daemon serves `fs-v1` (it seeds under the same
/// roots).
#[must_use]
pub fn installed() -> Option<&'static GitSeedService> {
    let fs = crate::fs_ops::installed()?;
    Some(SERVICE.get_or_init(|| GitSeedService::new(fs.roots().clone())))
}

/// The capability to advertise in `identify`, when served.
#[must_use]
pub fn advertised() -> Option<&'static str> {
    crate::fs_ops::installed().map(|_| GIT_SEED_CAPABILITY)
}

/// The `cmd` of `line` when it is one of [`GIT_SEED_COMMANDS`], exactly.
#[must_use]
pub fn frame_command(line: &str) -> Option<&'static str> {
    let value: Value = serde_json::from_str(line).ok()?;
    let object = value.as_object()?;
    // A frame with `protocol` goes to the resource router, never here.
    if object.contains_key("protocol") {
        return None;
    }
    let cmd = object.get("cmd")?.as_str()?;
    GIT_SEED_COMMANDS.iter().copied().find(|known| *known == cmd)
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
