//! Which acpmux harness may answer for the Chief (Lawrence, 2026-10-05:
//! "we have our own version that uses claude code cli stdio, ensure only
//! that one is being used").
//!
//! A Claude harness is admitted only when acpmux reports it as kind
//! `claude-stdio`: acpmux's own Claude Code adapter (`claude_stdio`), which
//! drives `claude -p --input-format stream-json`. An external ACP adapter
//! (`claude-acp`, kind `acp`) is refused, whatever its profile is named. An
//! acpmux can carry one under the reserved names: `~/.acpx` entries are
//! imported as kind `acp`, and a failing `sr claude proxy` launcher is
//! replaced by a copy of the `claude` profile.
//!
//! The reserved names are routes, not profile names: `claude-sr` asks for a
//! `claude-stdio` profile whose command is `sr claude proxy` (the team
//! subrouter pool), `claude` for one whose command is `claude` (the direct
//! login). The profile is found by kind and command in `_acpmux/harnesses`,
//! so a user profile named `claude` that runs an ACP adapter is never
//! picked. Any other harness keeps its name; a Claude-family one must still
//! be kind `claude-stdio`. Codex and the other families are not Claude and
//! are admitted as acpmux reports them.

use serde::Serialize;
use serde_json::Value;

use crate::acpmux::{AgentPort, Family, harness_family};
use crate::trace::Trace;

/// acpmux's kind for its own Claude Code adapter.
pub const CLAUDE_STDIO: &str = "claude-stdio";

/// A harness the gate admitted: the acpmux profile a session asks for, and
/// what acpmux says it runs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Admitted {
    /// The name the Chief was configured with (`claude-sr`, `codex`, ...).
    pub requested: String,
    /// The acpmux profile that matched: the session's `harness`.
    pub profile: String,
    /// acpmux's kind for it (`claude-stdio`, `acp`).
    pub kind: String,
    /// The first word of its command (the executable path).
    pub argv0: String,
    #[serde(skip)]
    pub family: Family,
}

impl Admitted {
    /// `claude-sr -> claude-sr (claude-stdio, /Users/me/bin/sr)`.
    pub fn describe(&self) -> String {
        let name = if self.requested == self.profile {
            self.profile.clone()
        } else {
            format!("{} -> {}", self.requested, self.profile)
        };
        format!("{name} ({}, {})", self.kind, self.argv0)
    }
}

/// What a reserved name asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    /// `claude-sr`: `sr claude proxy`, the subrouter account pool.
    Subrouter,
    /// `claude`: the `claude` executable, the direct login.
    Direct,
}

impl Route {
    pub fn of(name: &str) -> Option<Route> {
        match name {
            "claude-sr" => Some(Route::Subrouter),
            "claude" => Some(Route::Direct),
            _ => None,
        }
    }

    fn command(self) -> &'static str {
        match self {
            Route::Subrouter => "`sr claude proxy`",
            Route::Direct => "`claude`",
        }
    }

    /// Whether a profile's command is this route's.
    fn matches(self, argv: &[String]) -> bool {
        let Some(first) = argv.first() else {
            return false;
        };
        let exe = basename(first);
        match self {
            // `sr` is a symlink to `subrouter` on some machines.
            Route::Subrouter => {
                matches!(exe.as_str(), "sr" | "subrouter")
                    && argv
                        .get(1..)
                        .is_some_and(|rest| rest == ["claude", "proxy"])
            }
            Route::Direct => exe == "claude",
        }
    }
}

fn basename(word: &str) -> String {
    std::path::Path::new(word)
        .file_name()
        .map(|f| f.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn kind_of(profile: &Value) -> String {
    // acpmux omits the default kind (`acp`) when it serializes a profile.
    profile
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or("acp")
        .to_owned()
}

fn argv_of(profile: &Value) -> Vec<String> {
    profile
        .get("argv")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect()
}

fn profiles(answer: &Value) -> impl Iterator<Item = (&String, &Value)> {
    answer
        .get("harnesses")
        .and_then(Value::as_object)
        .into_iter()
        .flatten()
}

/// One profile as acpmux reports it, for a refusal message.
fn what_is(answer: &Value, name: &str) -> String {
    match answer.get("harnesses").and_then(|h| h.get(name)) {
        Some(p) => {
            let argv = argv_of(p);
            let mut text = format!(
                "acpmux's {name} is kind {} ({})",
                kind_of(p),
                argv.first().map_or("no command", String::as_str)
            );
            if let Some(why) = p.get("description").and_then(Value::as_str) {
                text.push_str(&format!(", \"{why}\""));
            }
            text
        }
        None => format!("acpmux has no harness named {name}"),
    }
}

/// The profile `requested` runs on, from an `_acpmux/harnesses` answer, or
/// why the Chief refuses it.
pub fn admit(answer: &Value, requested: &str) -> Result<Admitted, String> {
    if let Some(route) = Route::of(requested) {
        let matching = |(_, p): &(&String, &Value)| {
            kind_of(p) == CLAUDE_STDIO
                && p.get("unavailable").is_none()
                && route.matches(&argv_of(p))
        };
        let mut found: Vec<(&String, &Value)> = profiles(answer).filter(matching).collect();
        // The profile of the reserved name first, when it is the route's.
        found.sort_by_key(|(name, _)| (name.as_str() != requested, name.to_string()));
        let Some((name, p)) = found.first() else {
            return Err(format!(
                "the Chief runs Claude only through acpmux's own Claude Code adapter (kind {CLAUDE_STDIO}), and {requested} asks for one running {}; acpmux has none: {}",
                route.command(),
                what_is(answer, requested)
            ));
        };
        return Ok(Admitted {
            requested: requested.to_owned(),
            profile: (*name).clone(),
            kind: CLAUDE_STDIO.to_owned(),
            argv0: argv_of(p).first().cloned().unwrap_or_default(),
            family: Family::Claude,
        });
    }
    admit_profile(answer, requested).map(|mut a| {
        a.requested = requested.to_owned();
        a
    })
}

/// A profile by its exact name (a session's harness after acpmux resolved
/// it): refused when it is Claude and not kind `claude-stdio`.
pub fn admit_profile(answer: &Value, profile: &str) -> Result<Admitted, String> {
    let Some(p) = answer.get("harnesses").and_then(|h| h.get(profile)) else {
        return Err(format!("acpmux has no harness named {profile}"));
    };
    let family = harness_family(answer, profile)?;
    let kind = kind_of(p);
    if family == Family::Claude && kind != CLAUDE_STDIO {
        return Err(format!(
            "the Chief runs Claude only through acpmux's own Claude Code adapter (kind {CLAUDE_STDIO}); {}",
            what_is(answer, profile)
        ));
    }
    Ok(Admitted {
        requested: profile.to_owned(),
        profile: profile.to_owned(),
        kind,
        argv0: argv_of(p).first().cloned().unwrap_or_default(),
        family,
    })
}

/// The text the Chief posts for a refused turn.
pub fn refusal(reason: &str) -> String {
    format!(
        "refused: {reason}. Fix the acpmux harness (`acpmux daemon harnesses` lists them; `sr claude proxy --version` must succeed for claude-sr) and send the message again."
    )
}

/// Admits `requested` against the daemon's current harnesses (asked at each
/// session, so a daemon restarted with other profiles is seen at once).
pub fn admit_live(agents: &dyn AgentPort, requested: &str) -> Result<Admitted, String> {
    let answer = agents
        .harness_catalog()
        .map_err(|e| format!("acpmux did not say what its harnesses are ({e})"))?;
    admit(&answer, requested)
}

/// The harness acpmux actually runs session `id` on: `admitted` when it is
/// the one asked for (or acpmux does not say), else that other profile,
/// refused unless it too is allowed (a family preference or a fallback can
/// move a session onto another profile).
pub fn session_harness(
    agents: &dyn AgentPort,
    id: &str,
    admitted: &Admitted,
) -> Result<Admitted, String> {
    let actual = match agents.session(id) {
        Ok(Some(summary)) if !summary.harness.is_empty() => summary.harness,
        Ok(_) => return Ok(admitted.clone()),
        Err(e) => return Err(format!("acpmux did not say which harness runs {id} ({e})")),
    };
    if actual == admitted.profile {
        return Ok(admitted.clone());
    }
    let answer = agents
        .harness_catalog()
        .map_err(|e| format!("acpmux did not say what its harnesses are ({e})"))?;
    admit_profile(&answer, &actual)
        .map(|mut a| {
            a.requested = admitted.requested.clone();
            a
        })
        .map_err(|e| {
            format!(
                "acpmux runs the session on {actual}, not {}: {e}",
                admitted.profile
            )
        })
}

/// The trace's `harness.refused`: which Chief session (`role`), the harness
/// it asked for, and why.
pub fn trace_refusal(trace: &Trace, role: &str, requested: &str, reason: &str) {
    trace.emit(
        "harness.refused",
        serde_json::json!({"role": role, "harness": requested, "reason": reason}),
    );
}

/// A harness at host start: the family its sessions are laid out for, the
/// profile its presets name, and the admission.
#[derive(Clone, Debug)]
pub struct Plan {
    pub family: Family,
    pub profile: String,
    pub admitted: Result<Admitted, String>,
}

/// Plans `requested` from the start-up answer. A refused harness keeps the
/// host running (each of its sessions is refused in the chat until acpmux
/// has the adapter): a reserved name is laid out as Claude, another name as
/// acpmux reports it, and its presets name it as asked.
pub fn plan(answer: &Value, requested: &str) -> Plan {
    let admitted = admit(answer, requested);
    match &admitted {
        Ok(a) => Plan {
            family: a.family,
            profile: a.profile.clone(),
            admitted,
        },
        Err(_) => Plan {
            family: if Route::of(requested).is_some() {
                Family::Claude
            } else {
                harness_family(answer, requested).unwrap_or(Family::Other)
            },
            profile: requested.to_owned(),
            admitted,
        },
    }
}
