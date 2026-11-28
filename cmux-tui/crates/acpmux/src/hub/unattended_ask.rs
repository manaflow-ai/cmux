//! Part of `Hub`; see `hub/mod.rs`. A permission prompt in a chat nobody attends is refused after
//! a bound, not left open for ever.
//!
//! An agent or a script that starts a chat (`acpmux new -d`, a lane tool, a `start_session` tool)
//! with no `--policy` gets the daemon's (`ask`, or `approve-reads` on a lane host). A Codex shell
//! command that does more than read then asked a person who was never there, and the chat sat in
//! Waiting until somebody noticed (2026-11-27, interim-coord-2: "stuck permission prompts").
//!
//! The rule, all in the daemon (Leo: new logic in Rust, not in the shell or Python wrappers):
//! - It holds only for a chat an agent or a script created (`SessionMeta::created_by`,
//!   `hub/created_by.rs`). A chat the person created, and one with no record of its creator (a
//!   fork, a moved-in chat, one older than the record), waits as before.
//! - Only under a policy that leaves the prompt to a person (`ask`, `approve-reads`,
//!   `approve-edits`); `review` and `deny-all` already answer at once, `approve-all` asks nothing.
//!   A question (`questions::needs_person`) is not a tool call and still waits.
//! - The prompt stays open for [`BOUND`] (`ACPMUX_UNATTENDED_ASK_SECS`; 0 turns it off). The
//!   person, an ancestor agent (`subsession_answer.rs`) or any client may answer it meanwhile.
//! - At the bound, a chat some client is attached to (`Session::attached`: the app showing it,
//!   `acpmux attach`) keeps waiting another bound: a person may be in it. Otherwise the prompt is
//!   rejected (its reject option, else cancelled), with reason `permission.unattended`, the
//!   command, and the fix (`--policy review` or `--policy approve-all`) in the answer's
//!   `_meta.acpmux` and in the chat's `permission_decision` record.
//!
//! It never widens a policy: the only answer it gives is a refusal.

use super::*;
use crate::config::PermissionPolicy;
use crate::store::CreatorKind;
use std::time::Duration;

/// The environment variable that sets the bound in seconds (0: off).
pub(crate) const BOUND_ENV: &str = "ACPMUX_UNATTENDED_ASK_SECS";
/// How long a prompt in an unattended chat waits before it is refused.
pub(crate) const BOUND: Duration = Duration::from_secs(600);
/// The reason a refusal carries.
pub(crate) const REASON: &str = "permission.unattended";

/// The bound in force: [`BOUND`], or [`BOUND_ENV`]'s; None when it is off.
pub(crate) fn bound() -> Option<Duration> {
    bound_from(std::env::var(BOUND_ENV).ok().as_deref())
}

pub(crate) fn bound_from(env: Option<&str>) -> Option<Duration> {
    match env.map(str::trim).filter(|v| !v.is_empty()) {
        None => Some(BOUND),
        Some(v) => match v.parse::<u64>() {
            Ok(0) => None,
            Ok(secs) => Some(Duration::from_secs(secs)),
            Err(_) => {
                tracing::warn!("{BOUND_ENV}={v:?} is not a number of seconds; using {BOUND:?}");
                Some(BOUND)
            }
        },
    }
}

/// Whether a chat created by `created_by` running `policy` refuses a tool prompt nobody answers.
pub(crate) fn applies(
    created_by: Option<&crate::store::CreatedBy>,
    policy: PermissionPolicy,
) -> bool {
    let unattended =
        created_by.is_some_and(|c| matches!(c.kind, CreatorKind::Agent | CreatorKind::Script));
    let leaves_to_person = matches!(
        policy,
        PermissionPolicy::Ask | PermissionPolicy::ApproveReads | PermissionPolicy::ApproveEdits
    );
    unattended && leaves_to_person
}

/// What the prompt `request` asked to run, for the refusal: its shell command, else its title.
fn what(request: &Value) -> String {
    let call = request.get("toolCall");
    let command = call.and_then(|c| c.pointer("/rawInput/command")).and_then(|c| match c {
        Value::String(s) => Some(s.clone()),
        Value::Array(parts) => {
            Some(parts.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "))
        }
        _ => None,
    });
    let text = command
        .or_else(|| call.and_then(|c| c.get("title")).and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_else(|| "a tool call".to_owned());
    // One line, short: it goes into a log record and an agent's context.
    let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() > 200 {
        format!("{}…", line.chars().take(200).collect::<String>())
    } else {
        line
    }
}

/// The refusal's message and `_meta.acpmux`.
pub(crate) fn refusal(request: &Value, policy: PermissionPolicy, waited: Duration) -> Value {
    let what = what(request);
    let mins = waited.as_secs().div_ceil(60);
    let message = format!(
        "{REASON}: nobody attended this chat for {mins} min, so `{what}` was refused under the \
         {policy} policy. Start an unattended chat with `--policy review` (reads run, the rest is \
         refused at once) or `--policy approve-all`; or answer it from a client attached to the chat."
    );
    json!({"reason": REASON, "message": message, "command": what, "policy": policy.to_string(),
           "waitedSecs": waited.as_secs()})
}

impl Hub {
    /// Waits for the answer to the open prompt `permission_id` (`rx`), refusing it once it waited
    /// `bound` with no client attached to the chat (module docs). The answer, as `rx` gives it.
    pub(super) async fn await_or_refuse_unattended(
        &self,
        session: &Session,
        permission_id: &str,
        request: &Value,
        policy: PermissionPolicy,
        mut rx: oneshot::Receiver<Value>,
        bound: Duration,
    ) -> Value {
        let mut waited = Duration::ZERO;
        loop {
            match tokio::time::timeout(bound, &mut rx).await {
                Ok(answer) => return answer.unwrap_or_else(|_| json!({"outcome": "cancelled"})),
                Err(_) => waited += bound,
            }
            if session.attached.load(Ordering::SeqCst) != 0 {
                // A client holds the chat: a person may be in it. Never refused under them.
                continue;
            }
            let options = request.get("options").and_then(Value::as_array);
            let reject = ["reject_once", "reject_always"].into_iter().find_map(|kind| {
                options?
                    .iter()
                    .find(|o| o.get("kind").and_then(Value::as_str) == Some(kind))?
                    .get("optionId")?
                    .as_str()
                    .map(str::to_owned)
            });
            let why = refusal(request, policy, waited);
            let mut outcome = match &reject {
                Some(id) => json!({"outcome": "selected", "optionId": id}),
                None => json!({"outcome": "cancelled"}),
            };
            outcome.set("_meta", json!({"acpmux": why.clone()}));
            let taken = {
                let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
                if state.pending.contains_key(permission_id) {
                    state.settled.remember(permission_id, None, &outcome);
                    if let Some(group) = state.finish_item(&session.id, permission_id, true) {
                        self.append(session, "mux", "permission_group", json!({"group": group}));
                    }
                    state.pending.remove(permission_id)
                } else {
                    None
                }
            };
            // Answered between the bound and the lock: that answer is on its way through `rx`.
            if taken.is_none() {
                continue;
            }
            tracing::info!(session = %session.id, %permission_id, %policy, "refused a prompt nobody attended");
            // The reason goes to the agent and into the chat's `permission_decision` record
            // (`settle_permission`), which drops the card.
            return outcome;
        }
    }
}

#[cfg(test)]
#[path = "unattended_ask_tests.rs"]
mod tests;
