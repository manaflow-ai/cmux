//! Raw protocol handlers and the sender of Send Later on the local
//! conversation owner (`conversation-scheduled-v1`, cmux#25634,
//! conversation_scheduled.rs): a trusted local connection (the person's page
//! or terminal, a bound Chief) queues its own `message.send` for a time,
//! lists, edits, cancels or sends it now; one sender thread commits each
//! message when it comes due, as its author.

use std::sync::{Arc, Weak};
use std::time::Duration;

use cmux_conversation::{Op, Part};
use serde::Deserialize;
use serde_json::{Value, json};

use super::conversations::{decode, require_local};
use super::{Mux, MuxEvent};
use crate::conversation_store::ConversationEvent;
use crate::conversation_store::scheduled::{
    Delivery, ScheduleRejected, ScheduledEdit, ScheduledMessage,
};

/// `conversation-scheduled-list`, `conversation-scheduled-op` and the
/// `conversation-scheduled-changed` event on `subscribe`.
pub const CONVERSATION_SCHEDULED_CAPABILITY: &str = "conversation-scheduled-v1";

/// The longest the sender waits before it reads the clock again while a
/// message waits: a monotonic wait stops while the Mac sleeps, so a long one
/// would send late after a wake.
const MAX_WAIT: Duration = Duration::from_secs(60);

/// `conversation-scheduled-list`: the caller's waiting and failed messages,
/// of one conversation when `conversation` is set.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ListParams {
    #[serde(default)]
    conversation: Option<String>,
}

/// `conversation-scheduled-op`: one change of the caller's queue.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct OpParams {
    op: Value,
}

#[derive(Deserialize)]
#[serde(tag = "kind", deny_unknown_fields)]
enum ScheduledOp {
    /// Queue `send` (a `message.send` op) in `conversation` for `send_at_ms`.
    #[serde(rename = "scheduled.create")]
    Create { conversation: String, send_at_ms: u64, send: Value },
    /// A new time and/or new parts; a failed message waits again.
    #[serde(rename = "scheduled.update")]
    Update {
        id: String,
        #[serde(default)]
        send_at_ms: Option<u64>,
        #[serde(default)]
        parts: Option<Vec<Part>>,
    },
    #[serde(rename = "scheduled.cancel")]
    Cancel { id: String },
    #[serde(rename = "scheduled.send_now")]
    SendNow { id: String },
}

fn now_ms() -> anyhow::Result<u64> {
    crate::workspace_registry::unix_epoch_ms()
}

/// Send Later stays on the person's own local connections, never the relay.
fn require_owner_connection(mux: &Mux, client: u64) -> anyhow::Result<()> {
    anyhow::ensure!(!mux.is_remote_client(client), "scheduled messages are local only");
    require_local(mux, client)
}

pub(super) fn list(mux: &Mux, client: u64, params: ListParams) -> anyhow::Result<Value> {
    require_owner_connection(mux, client)?;
    let actor = mux.conversation_principal(client);
    let scheduled = mux.with_conversations(|store| {
        store.scheduled_messages(&actor, params.conversation.as_deref())
    })?;
    Ok(json!({"scheduled": scheduled}))
}

pub(super) fn op(mux: &Mux, client: u64, params: OpParams) -> anyhow::Result<Value> {
    require_owner_connection(mux, client)?;
    let actor = mux.conversation_principal(client);
    let op: ScheduledOp = decode(params.op, "op")?;
    let reply = match op {
        ScheduledOp::Create { conversation, send_at_ms, send } => {
            let send: Op = decode(send, "send")?;
            let now = now_ms()?;
            let (scheduled, created) = mux.conversation_write(
                |store| store.schedule_send(&conversation, &actor, &send, send_at_ms, now),
                |(scheduled, created)| created.then(|| changed(scheduled)),
            )?;
            json!({"scheduled": scheduled, "replayed": !created})
        }
        ScheduledOp::Update { id, send_at_ms, parts } => {
            let now = now_ms()?;
            let scheduled = mux.conversation_write(
                |store| store.edit_scheduled(&actor, &id, ScheduledEdit { send_at_ms, parts }, now),
                |scheduled| Some(changed(scheduled)),
            )?;
            json!({"scheduled": scheduled})
        }
        ScheduledOp::Cancel { id } => {
            let scheduled = mux.conversation_write(
                |store| store.cancel_scheduled(&actor, &id),
                |scheduled| Some(removed(scheduled, "cancelled", None)),
            )?;
            json!({"removed": {"id": scheduled.id, "reason": "cancelled"}})
        }
        ScheduledOp::SendNow { id } => {
            let author = mux.with_conversations(|store| store.scheduled_author(&id))?;
            if author.as_deref() != Some(actor.as_str()) {
                return Err(ScheduleRejected("unknown_scheduled").into());
            }
            match deliver(mux, &id, None)? {
                Delivery::Sent { scheduled, outcome } => json!({
                    "removed": {"id": scheduled.id, "reason": "sent", "seq": outcome.result.seq},
                    "rev": outcome.result.rev,
                    "change": outcome.result.change,
                }),
                Delivery::Failed { scheduled } => json!({"scheduled": scheduled}),
                Delivery::Postponed => {
                    let scheduled = mux.with_conversations(|store| {
                        store
                            .scheduled_messages(&actor, None)
                            .map(|all| all.into_iter().find(|scheduled| scheduled.id == id))
                    })?;
                    json!({"scheduled": scheduled})
                }
                Delivery::Gone => return Err(ScheduleRejected("unknown_scheduled").into()),
            }
        }
    };
    // The sender looks again: a new time, a removed message or one already due.
    mux.scheduled_sender_wake().notify();
    Ok(reply)
}

fn changed(scheduled: &ScheduledMessage) -> MuxEvent {
    MuxEvent::Conversation(Arc::new(ConversationEvent::Scheduled {
        conversation: scheduled.conversation.clone(),
        participant: scheduled.author.clone(),
        scheduled: serde_json::to_value(scheduled).ok(),
        removed: None,
    }))
}

fn removed(scheduled: &ScheduledMessage, reason: &'static str, seq: Option<u64>) -> MuxEvent {
    MuxEvent::Conversation(Arc::new(ConversationEvent::Scheduled {
        conversation: scheduled.conversation.clone(),
        participant: scheduled.author.clone(),
        scheduled: None,
        removed: Some((scheduled.id.clone(), reason, seq)),
    }))
}

/// Sends message `id` (`due_at`: see `deliver_scheduled`) and publishes what
/// became of it: the message's `conversation-changed` (so a Chief wakes as
/// for a live send) and the queue's `conversation-scheduled-changed`.
fn deliver(mux: &Mux, id: &str, due_at: Option<u64>) -> anyhow::Result<Delivery> {
    mux.conversation_write_many(
        |store| store.deliver_scheduled(id, due_at),
        |delivery| match delivery {
            Delivery::Sent { scheduled, outcome } => {
                let mut events = Vec::with_capacity(2);
                if !outcome.replayed {
                    events.push(MuxEvent::Conversation(Arc::new(ConversationEvent::Changed {
                        conversation: scheduled.conversation.clone(),
                        rev: outcome.result.rev,
                        transaction: None,
                        change: outcome.result.change.clone(),
                    })));
                }
                events.push(removed(scheduled, "sent", outcome.result.seq));
                events
            }
            Delivery::Failed { scheduled } => vec![changed(scheduled)],
            Delivery::Postponed | Delivery::Gone => Vec::new(),
        },
    )
}

/// Sends everything due now; returns when to look next (`None`: nothing
/// waits). A delivery that fails in the store (a full disk) leaves its row
/// due: the next look is then no sooner than `MAX_WAIT`, never a tight loop.
fn send_due(mux: &Mux) -> anyhow::Result<Option<u64>> {
    let now = now_ms()?;
    let due = mux.with_conversations(|store| store.due_scheduled(now))?;
    let mut failed = false;
    for id in due {
        if let Err(error) = deliver(mux, &id, Some(now)) {
            eprintln!("cmux-tui: scheduled message {id}: {error:#}");
            failed = true;
        }
    }
    let next = mux.with_conversations(|store| store.next_scheduled_due())?;
    let floor = now_ms()?.saturating_add(MAX_WAIT.as_millis() as u64);
    Ok(if failed { next.map(|next| next.max(floor)) } else { next })
}

/// Starts the Send Later sender once per mux, on its own thread (never on
/// the startup path): it sends what came due while the daemon was down, then
/// sleeps until the next due time or a change of the queue.
pub fn start_scheduled_sender(mux: &Arc<Mux>) {
    let wake = mux.scheduled_sender_wake();
    if !wake.claim_start() {
        return;
    }
    let weak = Arc::downgrade(mux);
    let _ = std::thread::Builder::new()
        .name("conversation-scheduled".into())
        .spawn(move || run_sender(&weak));
}

fn run_sender(weak: &Weak<Mux>) {
    let Some(wake) = weak.upgrade().map(|mux| mux.scheduled_sender_wake()) else { return };
    let mut seen = wake.generation();
    loop {
        let Some(mux) = weak.upgrade() else { return };
        let next = send_due(&mux).unwrap_or_else(|error| {
            eprintln!("cmux-tui: scheduled messages: {error:#}");
            // Look again after the cap, never in a tight loop.
            Some(now_ms().unwrap_or(0).saturating_add(MAX_WAIT.as_millis() as u64))
        });
        drop(mux);
        let timeout = next.map(|at| {
            let left = at.saturating_sub(now_ms().unwrap_or(at));
            Duration::from_millis(left).min(MAX_WAIT)
        });
        seen = wake.wait(seen, timeout);
    }
}
