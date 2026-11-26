//! A held chat: it takes no turn until the person asks for it. `acpmux session hold NAME`
//! (`_acpmux/session_hold {sessionId, held: true}`) and `acpmux session release NAME`
//! (`held: false`); `acpmux session hold --fleet --allow A,B` and `acpmux session release
//! --fleet` hold every chat on this machine but the allowlisted ones (`_acpmux/fleet_hold`).
//!
//! Leo, 2026-11-23: "PLEASE make sure the sessions STAY PAUSED IF NONESSENTIAL", "RIGHT NOW I
//! THINK THEY KEEP WAKING". A stopped chat starts again on any prompt: a merge notice, an inbox
//! notice, a background task's end, another agent's relay. 53 of about 860 stopped chats were
//! awake again within 1 to 3 hours.
//!
//! - What a hold keeps: every prompt no connection proved the person's
//!   (`PromptOptions::human_authenticated`): another agent's message, a tool's notice, its own
//!   background task's end, a workflow step, a loop. Each goes into the chat's inbox, whole and
//!   searchable, as a surge-held message (`inbox_surge.rs`), and no turn starts: the prompt is
//!   answered `end_turn` with `sessionHeld` in its receipt. acpmux's own inbox notice and digest,
//!   which only point at messages already in the inbox, are dropped. A continuation that only
//!   waits out a usage limit (`after_turn`) is refused.
//! - Nor does a daemon start run what a held chat's log left queued (`resume_restored`): it waits
//!   in place, as in a protected folder (`protected_hold.rs`).
//! - What wakes it: the person's own prompt, the person opening the chat in the app (a visible
//!   attach or view from the app or a proven person connection), or `session release`. Each lifts
//!   the hold (`release`), so the chat then runs as any other; under a fleet hold it is marked
//!   released, so the fleet hold no longer applies to it, until it is held again.
//! - A fleet hold also refuses `session/new` for a name not on its allowlist, unless the person
//!   asks for the chat (`Hub::fleet_hold_refuses_new`).
//! - `session hold` also pauses the chat's agent when it is idle (`pause.rs`): a harness still
//!   running could start a turn of its own (a Claude Code task notification) that acpmux cannot
//!   fence. A busy chat is held all the same; its running turn ends as it would.
//!
//! The chat's hold is its tag [`TAG`] (`on`, or `released` to exempt it from a fleet hold), so it
//! outlives a daemon restart. The fleet hold is [`FILE`] in the acpmux home, read again when it
//! changes.

use super::*;
use std::path::PathBuf;

/// The tag on a held chat: [`HELD`], or [`RELEASED`] for one let go under a fleet hold.
pub const TAG: &str = "acpmux.sessionHold";
const HELD: &str = "on";
const RELEASED: &str = "released";
/// The fleet hold, in the acpmux home.
pub const FILE: &str = "fleet-hold.json";
/// Listed in `initialize`'s `_meta.acpmux.features`.
pub(crate) const FEATURE: &str = "sessionHold";

/// The fleet hold as its file holds it.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FleetHold {
    pub on: bool,
    /// Chat names (or ids) it lets run: `NAME` exactly, `PREFIX*` a prefix, `*TERM*` any name
    /// containing TERM, in any case (the coordinators' KEEP list is such terms).
    #[serde(default)]
    pub allow: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default)]
    pub at: u64,
}

impl FleetHold {
    /// Whether the allowlist lets chat `name` (id `id`) run.
    pub fn allows(&self, name: &str, id: &str) -> bool {
        let lower = name.to_lowercase();
        self.allow.iter().any(|a| match a.strip_suffix('*') {
            Some(rest) => match rest.strip_prefix('*') {
                Some(term) => !term.is_empty() && lower.contains(&term.to_lowercase()),
                None => name.starts_with(rest) || id.starts_with(rest),
            },
            None => a == name || a == id,
        })
    }
}

/// The fleet hold a daemon read last, by the file's modification time.
#[derive(Default)]
pub(crate) struct FleetHoldCache {
    /// Tests: the file to read instead of the one in the acpmux home.
    pub(crate) path: Option<PathBuf>,
    read: Option<(Option<std::time::SystemTime>, FleetHold)>,
}

impl FleetHoldCache {
    fn path(&self) -> PathBuf {
        self.path.clone().unwrap_or_else(|| crate::config::home().join(FILE))
    }

    fn get(&mut self) -> FleetHold {
        // A test hub never reads the machine's own fleet hold.
        if cfg!(test) && self.path.is_none() {
            return FleetHold::default();
        }
        let path = self.path();
        let mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        if let Some((at, hold)) = &self.read
            && *at == mtime
        {
            return hold.clone();
        }
        let hold = mtime
            .and_then(|_| std::fs::read(&path).ok())
            .and_then(|b| serde_json::from_slice::<FleetHold>(&b).ok())
            .unwrap_or_default();
        self.read = Some((mtime, hold.clone()));
        hold
    }

    fn put(&mut self, hold: &FleetHold) -> std::io::Result<()> {
        let path = self.path();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(hold).unwrap_or_default())?;
        std::fs::rename(&tmp, &path)?;
        self.read = None;
        Ok(())
    }
}

/// The allowlist `session hold --fleet` sets: `current` plus `add`, in order, each entry once,
/// or `set` (`--set-allow`) plus `add` when it is given. `--allow` only ever adds, so admitting
/// one more session never drops the ones already allowed.
pub fn next_allow(current: &[String], set: Option<&[String]>, add: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for a in set.unwrap_or(current).iter().chain(add) {
        let a = a.trim();
        if !a.is_empty() && !out.iter().any(|o| o == a) {
            out.push(a.to_owned());
        }
    }
    out
}

fn tag_of(session: &Session) -> Option<String> {
    session
        .meta
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .tags
        .get(TAG)
        .map(|t| t.value.clone())
}

/// Whether a prompt only points at messages already in the inbox: acpmux's inbox notice or digest.
fn points_at_inbox(provenance: Option<&Value>) -> bool {
    super::inbox::is_notice(provenance) || super::digest::inbox_digest::is_digest(provenance)
}

impl Hub {
    pub(crate) fn fleet_hold(&self) -> FleetHold {
        self.fleet_hold.lock().unwrap_or_else(|e| e.into_inner()).get()
    }

    /// Whether `session` is held: its own hold, or the fleet hold when the allowlist does not
    /// name it and it was not released under it.
    pub(crate) fn session_held(&self, session: &Session) -> bool {
        match tag_of(session).as_deref() {
            Some(HELD) => true,
            Some(RELEASED) => false,
            _ => {
                let fleet = self.fleet_hold();
                fleet.on && !fleet.allows(&session.meta().name, &session.id)
            }
        }
    }

    /// `_acpmux/session_hold {sessionId, held}`: holds `session` (and pauses its agent when
    /// idle), or releases it, which runs what its log left queued.
    pub(crate) async fn set_session_hold(
        self: &Arc<Self>,
        session: &Arc<Session>,
        held: bool,
    ) -> Result<Value, RpcError> {
        let was = self.session_held(session);
        let mut set = serde_json::Map::new();
        set.insert(TAG.to_owned(), json!(if held { HELD } else { RELEASED }));
        self.set_tags_answered(session, Some(&set), &[], None)?;
        if was != held {
            self.append(session, "mux", "session_hold", json!({"held": held}));
        }
        let mut answer = json!({"sessionId": session.id, "held": held, "was": was});
        if held {
            // Best effort: a busy chat is held all the same.
            let paused = self.pause(session).await.ok();
            answer.set(
                "paused",
                json!(
                    paused.is_some_and(|p| p.get("paused").and_then(Value::as_bool) == Some(true))
                ),
            );
        } else if was {
            self.resume_restored(std::slice::from_ref(session));
        }
        Ok(answer)
    }

    /// The person asked for `session` (their prompt, or opened it in the app): a hold lifts.
    pub(crate) fn release_session_hold_for_person(self: &Arc<Self>, session: &Arc<Session>) {
        if !self.session_held(session) {
            return;
        }
        let mut set = serde_json::Map::new();
        set.insert(TAG.to_owned(), json!(RELEASED));
        if self.set_tags_answered(session, Some(&set), &[], None).is_ok() {
            tracing::info!(session = %session.id, "the person asked for a held chat: released");
            self.append(session, "mux", "session_hold", json!({"held": false, "by": "person"}));
            self.resume_restored(std::slice::from_ref(session));
        }
    }

    /// `_acpmux/fleet_hold {on, allow?, reason?}` sets the fleet hold; with no `on`, reads it.
    /// A chat's own tag stays as it is when the fleet hold changes.
    pub(crate) fn set_fleet_hold(&self, params: &Value) -> Result<Value, RpcError> {
        let mut cache = self.fleet_hold.lock().unwrap_or_else(|e| e.into_inner());
        let Some(on) = params.get("on").and_then(Value::as_bool) else {
            return Ok(json!({"fleetHold": cache.get()}));
        };
        let allow = params
            .get("allow")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default();
        let reason = params.get("reason").and_then(Value::as_str).map(str::to_owned);
        let hold = FleetHold { on, allow, reason, at: now_ms() };
        cache
            .put(&hold)
            .map_err(|e| RpcError::internal(format!("could not write the fleet hold: {e}")))?;
        drop(cache);
        tracing::info!(on, allow = ?hold.allow, "fleet hold set");
        let held =
            if on { self.sessions().iter().filter(|s| self.session_held(s)).count() } else { 0 };
        Ok(json!({"fleetHold": hold, "held": held}))
    }

    /// The refusal of a new chat named `name` while the fleet hold is on and its allowlist does
    /// not name it. The person's own ask passes.
    pub(crate) fn fleet_hold_refuses_new(
        &self,
        name: Option<&str>,
        person: bool,
    ) -> Option<RpcError> {
        if person {
            return None;
        }
        let fleet = self.fleet_hold();
        let name = name.unwrap_or_default();
        if !fleet.on || (!name.is_empty() && fleet.allows(name, "")) {
            return None;
        }
        Some(
            RpcError::invalid_params(format!(
                "fleet_hold: this machine's sessions are held{}; `{}` is not on the allowlist. `acpmux session release --fleet` lifts the hold, or `acpmux session hold --fleet --allow NAME` adds it to the allowlist",
                fleet.reason.as_deref().map(|r| format!(" ({r})")).unwrap_or_default(),
                if name.is_empty() { "a session with no name" } else { name },
            ))
            .with_data(json!({"reason": "fleet_hold", "allow": fleet.allow})),
        )
    }

    /// A prompt into a held chat that is not the person's: kept in its inbox, no turn
    /// (module docs). `None` when the prompt goes on as usual.
    pub(in crate::hub) fn hold_for_session_hold(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        client: &str,
        blocks: &[Value],
        opts: &PromptOptions,
    ) -> Result<Option<Value>, RpcError> {
        if opts.human_authenticated || !self.session_held(session) {
            return Ok(None);
        }
        if opts.after_turn.is_some() {
            return Err(RpcError::invalid_params(
                "session_held: a held session takes no continuation; `acpmux session release` lets it run",
            )
            .with_data(json!({"reason": "session_held", "sessionId": session.id})));
        }
        let provenance = opts.provenance.as_ref();
        if points_at_inbox(provenance) {
            return Ok(Some(json!({"sessionId": session.id, "promptId": prompt_id,
                "sessionHeld": true, "dropped": true, "queued": false})));
        }
        let from = super::digest::agent_sender(provenance, opts.agent.as_deref())
            .or_else(|| {
                provenance
                    .and_then(|p| p.pointer("/notice/sender"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .unwrap_or_else(|| client.to_owned());
        let mut receipt = self.hold_in_inbox(session, prompt_id, client, blocks, opts, from)?;
        receipt.set("sessionHeld", json!(true));
        Ok(Some(receipt))
    }
}

#[cfg(test)]
#[path = "session_hold_tests.rs"]
mod tests;
