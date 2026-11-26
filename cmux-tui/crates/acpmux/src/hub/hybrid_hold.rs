//! Part of `Hub`; see `hub/mod.rs`. A hybrid start's tool calls wait at the PreToolUse gate
//! (`policy_gate.rs`) while the chat's Cloud machine boots, then run on the machine (Leo,
//! 2026-11-23: "you're not even interrupting them. You're just giving them a sort of extended
//! wait ... It's like an extended tool call").
//!
//! The hybrid driver (`cmux cloud hybrid-drive`) keeps the chat's tags at its stage
//! (`cmux_cloud_start_core::hybrid_tools::STAGE_TAG`, `MACHINE_TAG`); every decision is
//! `hybrid_tools::route`'s. A chat with no such tag (every chat that is not a hybrid start) is
//! answered at once, as before. A held call's gate answer waits: a tag change wakes it
//! ([`tags_changed`], from `tags.rs`), never a timer, and the hold's deadline lets it run here as
//! before, with its reason logged. The answer is the call's one answer, so the agent sees only a
//! longer call: none added, none run twice.
//!
//! Routed to the machine, a Bash call keeps its own input with its command run by `cmux vm exec`
//! there (`hybrid_tools::on_machine_command`), under the gate's own decision (routing a call
//! never approves it: [`with_machine`]); the driver moves the chat at
//! that call's end, a tool boundary. A call the machine has no route for yet (a file read or
//! edit) runs here and says so.

use super::*;
use cmux_cloud_start_core::hybrid_tools::{self, Boot, Call, Route};
use std::sync::LazyLock;
use std::time::Duration;

/// Woken by every tag change: a held gate answer reads its chat's stage again.
static TAGS_CHANGED: LazyLock<Notify> = LazyLock::new(Notify::new);

/// A chat's tags changed (`tags.rs`): every held call reads its stage again.
pub(super) fn tags_changed() {
    TAGS_CHANGED.notify_waiters();
}

/// `meta`'s hybrid stage and machine, from its live tags.
pub(super) fn boot_tags(meta: &SessionMeta) -> (Option<String>, Option<String>) {
    let now = now_ms();
    let live = |key: &str| {
        meta.tags
            .get(key)
            .filter(|tag| tag.expires_at.is_none_or(|at| at > now))
            .map(|tag| tag.value.clone())
    };
    (live(hybrid_tools::STAGE_TAG), live(hybrid_tools::MACHINE_TAG))
}

/// `answer`, the gate's own decision for a call, with the call's input as it runs on its machine
/// (`on_machine`, from [`on_machine_answer`]). The decision stays the gate's: routing a call
/// never approves it, so a call the person would be asked about is still asked about, with the
/// command as it will run.
pub(super) fn with_machine(mut answer: Value, on_machine: Option<Value>) -> Value {
    let Some(routed) = on_machine else { return answer };
    if let (Some(answer), Some(routed)) = (answer.as_object_mut(), routed.as_object()) {
        for key in ["reason", "updatedInput"] {
            if let Some(value) = routed.get(key) {
                answer.insert(key.to_owned(), value.clone());
            }
        }
    }
    answer
}

/// A call routed to `machine`: `request`'s own input with its command run there, and why. None
/// when the call is not a Bash command (it then runs here).
pub(super) fn on_machine_answer(request: &Value, machine: &str) -> Option<Value> {
    let tool = request.pointer("/toolCall/_meta/claude/tool").and_then(Value::as_str);
    let input = request.pointer("/toolCall/rawInput").and_then(Value::as_object)?;
    let command = input.get("command").and_then(Value::as_str).filter(|_| tool == Some("Bash"))?;
    let mut updated = input.clone();
    updated.insert(
        "command".to_owned(),
        Value::String(hybrid_tools::on_machine_command(machine, command)),
    );
    Some(json!({
        "reason": format!("this call runs on the chat's Cloud machine {machine}"),
        "updatedInput": updated,
    }))
}

impl Hub {
    /// How `session`'s gated call of ACP kind `kind` runs: held while its hybrid start's machine
    /// boots, then routed (module docs). At once for a chat that is not a hybrid start.
    pub(super) async fn hybrid_route(&self, session: &Arc<Session>, kind: &str) -> Route {
        let began = std::time::Instant::now();
        let mut held = false;
        loop {
            // Armed before the tags are read, so a change between the read and the wait wakes it.
            let notified = TAGS_CHANGED.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            let (stage, machine) = session.read_meta(boot_tags);
            let held_ms = u64::try_from(began.elapsed().as_millis()).unwrap_or(u64::MAX);
            let boot = Boot {
                stage: hybrid_tools::stage_of(stage.as_deref()),
                machine: machine.as_deref(),
            };
            let route = hybrid_tools::route(&boot, &Call { kind, held_ms });
            if route != Route::Hold {
                if held {
                    tracing::info!(session = %session.id, held_ms, ?route, "a hybrid start's held tool call goes on");
                }
                return route;
            }
            if !held {
                held = true;
                tracing::info!(session = %session.id, kind, "a hybrid start holds a tool call until its machine is ready");
            }
            let left = hybrid_tools::HOLD_DEADLINE_MS.saturating_sub(held_ms).max(1);
            let _ = tokio::time::timeout(Duration::from_millis(left), notified).await;
        }
    }
}

#[cfg(test)]
#[path = "hybrid_hold_tests.rs"]
mod tests;
