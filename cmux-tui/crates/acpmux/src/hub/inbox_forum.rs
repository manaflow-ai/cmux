//! The receive-side seam between forum work posts (`forum/work.rs`) and the surge inbox
//! (`inbox_surge.rs`, `surge_triage.rs`).
//!
//! A typed work post is first stored in the forum journal (its durable receipt, with every
//! source's transport provenance). Then the post goes into the recipient's held inbox once, as
//! its parsed body under the topic `topic:<channel>/<thread>`, the same key the surge holder gives
//! an untyped runner-capacity or disk-recovery notice. That puts it on the one held-messages row,
//! routes it to the thread's authorized owner at triage, and keeps the sender's identity on the
//! held original. A repeat of the same key from another host adds a forum source and no second
//! row. A question, a blocker sent with an urgent transport class, a FIRE notice and the person's
//! message are never taken here: they keep their immediate delivery paths.
use super::surge::Original;
use super::*;
use crate::forum::work::{Input, Kind, PREFIX};

/// One projection at a time, so a post and a concurrent repeat of it from another host can't
/// both find no held row and add two.
static PROJECTING: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// The work post a prompt carries: its one text block, past any relay envelope, after the prefix.
pub(in crate::hub) fn wire(blocks: &[Value]) -> Option<&str> {
    let [block] = blocks else { return None };
    block.get("text").and_then(Value::as_str).and_then(|t| relay_body(t).strip_prefix(PREFIX))
}

pub(in crate::hub) fn is_wire(blocks: &[Value]) -> bool {
    wire(blocks).is_some()
}

/// The classes no store-and-hold path may take: the person's message, a question, a blocker
/// sent as one, and a FIRE notice.
pub(in crate::hub) fn protected(opts: &PromptOptions) -> bool {
    opts.human_authenticated
        || opts.class.is_some_and(PromptClass::urgent)
        || fire_notice(opts.provenance.as_ref().and_then(|p| p.get("notice")))
}

/// The surge topic of a forum thread. Runner and disk channels land on the surge holder's keys.
pub(in crate::hub) fn topic(channel: &str, thread: &str) -> String {
    format!("topic:{channel}/{thread}")
}

/// A blocker post is held as a blocker, which triage always sends to the chat itself.
fn class_of(kind: Kind) -> PromptClass {
    match kind {
        Kind::Blocker => PromptClass::Block,
        Kind::Receipt => PromptClass::Result,
        Kind::Status | Kind::Warn => PromptClass::Fyi,
    }
}

/// The held original's id: one per stored post, whichever host's copy carried it.
pub(in crate::hub) fn held_id(post_id: &str) -> String {
    format!("forum-{post_id}")
}

impl Hub {
    /// After `receipt` (the forum's durable acceptance of `input`), hold the post once in
    /// `session`'s surge inbox. Returns the hold receipt, or None when the post is already held
    /// or has no agent sender to attribute. A repeat whose first projection failed holds it now.
    #[allow(clippy::too_many_arguments)]
    pub(in crate::hub) fn hold_forum_work(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        client: &str,
        blocks: &[Value],
        opts: &PromptOptions,
        input: &Input,
        receipt: &Value,
        now: u64,
    ) -> Result<Option<Value>, RpcError> {
        let Some(post_id) = receipt["postId"].as_str() else { return Ok(None) };
        let Some(from) =
            super::super::digest::agent_sender(opts.provenance.as_ref(), opts.agent.as_deref())
        else {
            return Ok(None);
        };
        if session.moving().is_some() {
            return Err(super::super::queue::moving_error(session));
        }
        let id = held_id(post_id);
        let _one = PROJECTING.lock().unwrap_or_else(|e| e.into_inner());
        if session.inbox().items.iter().any(|item| item.prompt_id == id) {
            return Ok(None);
        }
        let extra = json!({"transportPromptId": prompt_id, "forum": {
            "postId": post_id, "channel": input.channel, "thread": input.thread,
            "kind": input.kind, "key": input.key, "source": input.source}});
        let held = Original {
            prompt_id: &id,
            client,
            blocks,
            opts,
            from,
            thread: topic(&input.channel, &input.thread),
            class: class_of(input.kind),
            text: input.body.clone(),
        };
        self.hold_original(session, held, extra, None, now).map(Some)
    }
}
