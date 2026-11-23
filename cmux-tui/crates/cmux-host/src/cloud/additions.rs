//! A person's image additions list, collected under the opt-in setting (sans I/O; cmuxterm-hq
//! `plans/cloud/images-per-user.md` step 2, "Collect, under the opt-in setting"): the package
//! names they added on this machine since its image, sent to the platform when the machine goes
//! idle, and only while their usage-sharing choice is on.
//!
//! - The choice: every `cloud.vm.status.report` reply may carry `usage_sharing` (cmux-platform
//!   reads the owner's install-counts consent). The machine keeps the last answered value, starts
//!   off, and reads a missing field as off ([`usage_sharing`]). Learning it sends no request.
//! - The moment: the edge into idle the status report already describes, a report with no
//!   open session and no acpmux turn after one that had some (or the first report)
//!   ([`Gate::report_answered`]). Only then, and only while the choice is on, is anything listed.
//! - The list: names only, `<kind> <name>`, the same lines `userAdditionsCommand()` in
//!   `web/scripts/cmux-vm-image/layers.ts` prints, minus the image's baseline
//!   ([`IMAGE_PACKAGES_FILE`]). With no baseline nothing is listed or sent ([`collect`]).
//! - The send: `POST /v1/install-counts/additions` as this machine's `vm` install, once per
//!   distinct list (its sha256 is kept in [`SENT_FILE`]), again only after it changed.
//!
//! The listing and the send run on their own thread (`additions_thread.rs`), never the poll loop.

use std::collections::BTreeSet;

use serde_json::{Value, json};
use sha2::Digest as _;

use super::sender::Answer;
use crate::json::JsonField;

/// The platform route (cmux-platform, under the install-counts surface).
pub const ADDITIONS_PATH: &str = "/v1/install-counts/additions";
/// The image's package names, one `kind name` per line, written at the image's finalize
/// (`IMAGE_PACKAGES_PATH` in layers.ts).
pub const IMAGE_PACKAGES_FILE: &str = "/etc/cmux/image-packages.txt";
/// The sha256 of the last list the platform stored, so a restart does not send it again.
pub const SENT_FILE: &str = "/var/lib/cmux/additions-sent";
/// The most names one body may carry (the route refuses more).
pub const MAX_NAMES: usize = 2000;
/// The longest name after its kind (the route refuses longer).
pub const MAX_NAME_LEN: usize = 214;
/// The kinds the list holds, as layers.ts names them.
pub const KINDS: [&str; 6] = ["apt", "npm", "bun", "uv", "pipx", "cargo"];

/// The `usage_sharing` of one status report answer: `Some` for an accepted report (a missing or
/// non-boolean field is off), `None` when the report was not answered (the last value stands).
/// Read at `value.usage_sharing`, where the reply's other fields are, or at the top level.
pub fn usage_sharing(answer: &Answer) -> Option<bool> {
    if !answer.ok() {
        return None;
    }
    let Answer::Http { body, .. } = answer else { return None };
    let field = match body.field("value").field("usage_sharing") {
        Value::Null => body.field("usage_sharing"),
        found => found,
    };
    Some(field.as_bool() == Some(true))
}

/// Whether a status report's activity says the machine is idle: no open session and no acpmux
/// turn (`active_sessions` counts both, `phases.turns` lists the turns at work).
pub fn report_idle(params: &Value) -> bool {
    let activity = params.field("activity");
    let sessions = activity.field("active_sessions").as_u64() == Some(0);
    let turns = activity.field("phases").field("turns").as_array().is_some_and(|t| !t.is_empty());
    sessions && !turns
}

/// The setting and the idle edge, fed every answered status report.
#[derive(Debug, Default)]
pub struct Gate {
    sharing: bool,
    /// Whether the last accepted report said idle; None before the first.
    idle: Option<bool>,
}

impl Gate {
    /// The person's choice as the last accepted report's reply carried it.
    pub fn sharing(&self) -> bool {
        self.sharing
    }

    /// One answered status report (`params` as sent): `true` when the list is to be collected
    /// now, at the edge into idle with the choice on. A report the Cloud did not accept changes
    /// nothing.
    pub fn report_answered(&mut self, params: &Value, answer: &Answer) -> bool {
        let Some(sharing) = usage_sharing(answer) else { return false };
        self.sharing = sharing;
        let idle = report_idle(params);
        let edge = idle && self.idle != Some(true);
        self.idle = Some(idle);
        edge && sharing
    }
}

/// Whether `line` is one name the route takes: `<kind> <name>`, a known kind, then 1 to
/// [`MAX_NAME_LEN`] of `[A-Za-z0-9@._+/-]` with no `..`.
pub fn valid_line(line: &str) -> bool {
    let Some((kind, name)) = line.split_once(' ') else { return false };
    KINDS.contains(&kind)
        && (1..=MAX_NAME_LEN).contains(&name.len())
        && !name.contains("..")
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"@._+/-".contains(&b))
}

/// The additions: every line of `now` not in `baseline` (`comm -13 baseline -`), each one the
/// route takes, sorted and unique, at most [`MAX_NAMES`].
pub fn additions(now: impl IntoIterator<Item = String>, baseline: &str) -> Vec<String> {
    let image: BTreeSet<&str> = baseline.lines().map(str::trim_end).collect();
    let set: BTreeSet<String> =
        now.into_iter().filter(|l| !image.contains(l.as_str()) && valid_line(l)).collect();
    set.into_iter().take(MAX_NAMES).collect()
}

/// The sha256 (lowercase hex) of a sorted list, one name per line.
pub fn list_hash(names: &[String]) -> String {
    let mut digest = sha2::Sha256::new();
    for name in names {
        digest.update(name.as_bytes());
        digest.update(b"\n");
    }
    digest.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// The route's body: the batch is the list's own hash (its first 24 hex), so a resent list is
/// the same batch.
pub fn body(names: &[String], hash: &str) -> Value {
    json!({ "batch": &hash[..24], "names": names })
}

/// What one collection did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// No `/etc/cmux/image-packages.txt`: nothing listed, nothing sent.
    NoBaseline,
    /// The same list as the one last stored: nothing sent.
    Unchanged,
    /// The platform stored it; `hash` is to be kept in [`SENT_FILE`].
    Stored { hash: String, names: usize },
    /// The person's choice is off at the platform (403 `install_counts.not_shared`).
    NotShared,
    /// Anything else; the next idle edge tries again.
    Failed(String),
}

/// One collection: with a baseline, list the names (`list`), drop the baseline's, and send the
/// list (`post`) unless its hash is `last_sent`.
pub fn collect(
    baseline: Option<&str>,
    list: impl FnOnce() -> Vec<String>,
    last_sent: Option<&str>,
    post: impl FnOnce(&Value) -> Answer,
) -> Outcome {
    let Some(baseline) = baseline else { return Outcome::NoBaseline };
    let names = additions(list(), baseline);
    let hash = list_hash(&names);
    if last_sent.map(str::trim) == Some(hash.as_str()) {
        return Outcome::Unchanged;
    }
    match post(&body(&names, &hash)) {
        Answer::Http { status: 200, .. } => Outcome::Stored { hash, names: names.len() },
        Answer::Http { status: 403, body }
            if body.field("error").field("code") == "install_counts.not_shared"
                || body.field("code") == "install_counts.not_shared" =>
        {
            Outcome::NotShared
        }
        Answer::Http { status, .. } => Outcome::Failed(format!("HTTP {status}")),
        Answer::Transport => Outcome::Failed("unreachable".to_owned()),
    }
}

/// The package names `dpkg-query -W -f='${Package}'` lists, from the dpkg status database's
/// text: every stanza's `Package`, unless its `Status` says `not-installed`.
pub fn dpkg_names(status: &str) -> Vec<String> {
    let mut out = Vec::new();
    for stanza in status.split("\n\n") {
        let mut package = None;
        let mut installed = true;
        for line in stanza.lines() {
            if let Some(name) = line.strip_prefix("Package:") {
                package = Some(name.trim());
            } else if let Some(status) = line.strip_prefix("Status:") {
                installed = status.split_whitespace().nth(2) != Some("not-installed");
            }
        }
        if let Some(name) = package.filter(|n| !n.is_empty() && installed) {
            out.push(format!("apt {name}"));
        }
    }
    out
}
