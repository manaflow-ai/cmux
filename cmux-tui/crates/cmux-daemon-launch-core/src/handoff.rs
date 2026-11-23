//! The version handoff (plans/cmux-next/durable-sessions.md section 3): which
//! running owner is another build than the bundled binary, the build a binary
//! reports, and when the app hands an owner off to the bundled build.
//!
//! The app keeps the handoff's bookkeeping (the keys it already began, the
//! pid that is exiting) and sends `shutdown-daemon`; this module names the
//! key and says whether a handoff runs at all ([`gate`]).

use serde::{Deserialize, Serialize};

/// The build of one cmux-tui binary: the stamped source commit (a packaged
/// build only) and the build identity (`build_id` in `identify`,
/// `build_identity` in `cmux --version --json`; the commit plus
/// `-dirty.<hash>` for an unstamped build, crate `cmux-build-identity`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stamp {
    #[serde(default)]
    pub commit: Option<String>,
    #[serde(default)]
    pub id: Option<String>,
}

impl Stamp {
    /// An empty commit or id counts as none.
    pub fn new(commit: Option<String>, id: Option<String>) -> Self {
        Self { commit: commit.filter(|c| !c.is_empty()), id: id.filter(|i| !i.is_empty()) }
    }

    fn normalized(&self) -> Self {
        Self::new(self.commit.clone(), self.id.clone())
    }

    /// The build in `cmux --version --json` output (`build_commit`,
    /// `build_identity`); none when the output is not a JSON object with
    /// string (or null) fields.
    pub fn from_version_json(text: &str) -> Option<Self> {
        #[derive(Deserialize)]
        struct Report {
            #[serde(default)]
            build_commit: Option<String>,
            #[serde(default)]
            build_identity: Option<String>,
        }
        let report: Report = serde_json::from_str(text).ok()?;
        Some(Self::new(report.build_commit, report.build_identity))
    }
}

/// The commit in `cmux --version` text (`cmux 0.1.0 (<commit>; ghostty …)`):
/// the hex digits right after the first `(`, at least 7 of them.
pub fn build_commit_from_version_text(text: &str) -> Option<String> {
    let (_, after) = text.split_once('(')?;
    let commit: String = after.chars().take_while(char::is_ascii_hexdigit).collect();
    (commit.chars().count() >= 7).then_some(commit)
}

/// What the app does with a running daemon of another build.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Decision {
    /// Keep it; the reason is for the log.
    Keep(String),
    /// Hand it off: the running build exits (its terminals live on) and the
    /// bundled one adopts them.
    Restart { running: String, bundled: String },
}

/// Whether the running owner is another build than the bundled binary. The
/// build identity decides when both sides have one; an owner older than
/// `daemon-build-v1` has none and the stamped commits decide. With neither,
/// the owner is kept and the reason names the unknown side.
pub fn version_decision(running: &Stamp, bundled: Option<&Stamp>) -> Decision {
    let running = running.normalized();
    let bundled = bundled.map(Stamp::normalized);
    if let (Some(running_id), Some(bundled_id)) =
        (&running.id, bundled.as_ref().and_then(|b| b.id.clone()))
    {
        return if *running_id == bundled_id {
            Decision::Keep("same build".into())
        } else {
            Decision::Restart { running: running_id.clone(), bundled: bundled_id }
        };
    }
    let Some(running) = running.commit else {
        return Decision::Keep("running build unknown".into());
    };
    let Some(bundled) = bundled.and_then(|b| b.commit) else {
        return Decision::Keep("bundled build unknown".into());
    };
    if running == bundled {
        Decision::Keep("same build".into())
    } else {
        Decision::Restart { running, bundled }
    }
}

/// Which handoff the app asks about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// After an update: the owner is another build (`handOffIfStale`).
    Stale,
    /// The owner lacks a capability the bundled build serves.
    Capability,
    /// The owner does not verify this app's install key.
    InstallKey,
    /// The person confirmed "Restart cmux-tui" for a server update.
    Update,
    /// The handshake refused the owner (another protocol).
    Incompatible,
}

/// One handoff question.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GateInput {
    pub kind: Kind,
    /// The launcher runs the app bundle's own `bin/cmux-tui`.
    #[serde(default)]
    pub binary_is_bundled: bool,
    /// The launcher holds an install key.
    #[serde(default)]
    pub has_install_key: bool,
    /// The owner's pid.
    #[serde(default)]
    pub pid: i32,
    /// The owner's session and the launcher's (incompatible only).
    #[serde(default)]
    pub session: Option<String>,
    #[serde(default)]
    pub configured_session: Option<String>,
    /// The capability (capability only) and whether the owner serves it.
    #[serde(default)]
    pub capability: Option<String>,
    #[serde(default)]
    pub supports: bool,
    /// The pid exiting for an earlier handoff, if any.
    #[serde(default)]
    pub exiting: Option<i32>,
    /// The owner's and the bundled binary's builds (stale only).
    #[serde(default)]
    pub running: Option<Stamp>,
    #[serde(default)]
    pub bundled: Option<Stamp>,
}

/// The answer: `skip` (no handoff), `wait` (that owner is still exiting for
/// this handoff), or `begin` with the key the app records once per launcher;
/// when that key was already begun the app keeps the owner with `refused`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Gate {
    pub action: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// Stale only: the version decision.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub decision: Option<Decision>,
    /// Stale only: the decision when the key was already begun.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refused: Option<Decision>,
}

impl Gate {
    fn skip() -> Self {
        Self { action: "skip", key: None, decision: None, refused: None }
    }
    fn wait() -> Self {
        Self { action: "wait", key: None, decision: None, refused: None }
    }
    fn begin(key: String) -> Self {
        Self { action: "begin", key: Some(key), decision: None, refused: None }
    }
}

/// Whether a handoff of `input.kind` runs, and under which key.
pub fn gate(input: &GateInput) -> Gate {
    let exiting = input.exiting == Some(input.pid);
    match input.kind {
        Kind::Stale => {
            let running = input.running.clone().unwrap_or_default();
            let decision = version_decision(&running, input.bundled.as_ref());
            match &decision {
                Decision::Keep(_) => Gate { decision: Some(decision), ..Gate::skip() },
                Decision::Restart { bundled, .. } => Gate {
                    refused: Some(Decision::Keep(format!("already handed off to {bundled}"))),
                    decision: Some(decision.clone()),
                    ..Gate::begin(bundled.clone())
                },
            }
        }
        Kind::Capability => {
            if !input.binary_is_bundled || input.supports {
                return Gate::skip();
            }
            if exiting {
                return Gate::wait();
            }
            Gate::begin(format!("capability:{}", input.capability.as_deref().unwrap_or_default()))
        }
        Kind::InstallKey => {
            if input.has_install_key {
                Gate::begin("install-key".into())
            } else {
                Gate::skip()
            }
        }
        Kind::Update => {
            if input.binary_is_bundled {
                Gate::begin(format!("update:{}", input.pid))
            } else {
                Gate::skip()
            }
        }
        Kind::Incompatible => {
            if !input.binary_is_bundled
                || input.pid <= 1
                || input.session != input.configured_session
            {
                return Gate::skip();
            }
            if exiting {
                return Gate::wait();
            }
            Gate::begin("incompatible".into())
        }
    }
}
