//! The one place that reads daemon events for `cmux chief`. `adapt` turns a
//! `conversation.events` item into a UI event of the Chief conversation;
//! `Drafts` keeps the Chief's live reply from its `draft` items. Drafts are
//! ephemeral: the posted message is the only authoritative reply, so every
//! draft of a turn is dropped when that message arrives, on `done`, or when
//! the Chief stops typing.

use serde_json::Value;

/// The Chief's participant id in its conversation.
pub(super) const AGENT_MUX: &str = "agent_mux";

#[derive(Clone, Debug, PartialEq)]
pub(super) enum UiEvent {
    /// The stream's first item: the summary and the last messages.
    Snapshot {
        summary: Value,
        messages: Vec<Value>,
        /// The participants typing when the snapshot was taken.
        typing: Vec<String>,
    },
    /// A new message.
    Message(Value),
    /// An edited or retracted message.
    Updated(Value),
    /// The conversation's summary changed (title, participants).
    Summary(Value),
    Typing {
        participant: String,
        on: bool,
    },
    Cursor {
        participant: String,
        seq: u64,
    },
    Draft(Draft),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum DraftKind {
    Talk,
    Thought,
}

/// One draft item: the Chief's live reply text.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Draft {
    pub participant: String,
    /// The idempotency key of the reply message this draft becomes.
    pub turn: String,
    /// The segment of the turn (a new one starts after each tool call).
    pub segment: u64,
    pub seq: u64,
    pub kind: DraftKind,
    pub text: String,
    pub fresh: bool,
    pub done: bool,
}

/// The UI event of one `conversation.events` item of `conversation`, or
/// None (another conversation, an unknown item type, a malformed item).
pub(super) fn adapt(item: &Value, conversation: &str) -> Option<UiEvent> {
    let kind = item.get("type")?.as_str()?;
    let of = match kind {
        "snapshot" => item.pointer("/conversation/id"),
        _ => item.get("conversation"),
    };
    if of.and_then(Value::as_str) != Some(conversation) {
        return None;
    }
    let text = |key: &str| item.get(key).and_then(Value::as_str).map(str::to_owned);
    match kind {
        "snapshot" => Some(UiEvent::Snapshot {
            summary: item.get("conversation")?.clone(),
            messages: item.get("messages").and_then(Value::as_array).cloned().unwrap_or_default(),
            typing: item
                .get("typing")
                .and_then(Value::as_array)
                .map(|ids| ids.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default(),
        }),
        "message" => Some(UiEvent::Message(item.get("message")?.clone())),
        "message_updated" => Some(UiEvent::Updated(item.get("message")?.clone())),
        "conversation" => Some(UiEvent::Summary(item.get("summary")?.clone())),
        "read_cursor" => Some(UiEvent::Cursor {
            participant: text("participant")?,
            seq: item.get("seq")?.as_u64()?,
        }),
        "typing" => Some(UiEvent::Typing {
            participant: text("participant")?,
            on: item.get("on")?.as_bool()?,
        }),
        "draft" => Some(UiEvent::Draft(Draft {
            participant: text("participant")?,
            turn: text("turn")?,
            segment: item.get("segment").and_then(Value::as_u64).unwrap_or(0),
            seq: item.get("seq").and_then(Value::as_u64).unwrap_or(0),
            kind: if text("kind").as_deref() == Some("thought") {
                DraftKind::Thought
            } else {
                DraftKind::Talk
            },
            text: text("text").unwrap_or_default(),
            fresh: item.get("fresh").and_then(Value::as_bool).unwrap_or(false),
            done: item.get("done").and_then(Value::as_bool).unwrap_or(false),
        })),
        _ => None,
    }
}

/// One turn's live text: segments by index, each talk or thought.
#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct TurnDraft {
    pub participant: String,
    pub turn: String,
    pub segments: std::collections::BTreeMap<u64, (DraftKind, String)>,
    last_seq: u64,
    /// A seq was missed: nothing new shows until the next `fresh`.
    gap: bool,
}

impl TurnDraft {
    /// The talk text so far (segments joined by a blank line).
    pub(super) fn talk(&self) -> String {
        let talk: Vec<&str> = self
            .segments
            .values()
            .filter(|(kind, _)| *kind == DraftKind::Talk)
            .map(|(_, text)| text.as_str())
            .collect();
        talk.join("\n\n")
    }
}

/// The live drafts of every participant's running turn.
#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct Drafts {
    pub turns: Vec<TurnDraft>,
}

impl Drafts {
    /// Applies one draft item. A `fresh` item sets its segment's whole text;
    /// a delta appends to its segment only when its seq follows the last
    /// one; after a gap nothing new shows until the next `fresh` item.
    pub(super) fn apply(&mut self, draft: &Draft) {
        if draft.done {
            self.drop_turn(&draft.participant, &draft.turn);
            return;
        }
        let index = match self
            .turns
            .iter()
            .position(|t| t.participant == draft.participant && t.turn == draft.turn)
        {
            Some(index) => index,
            None => {
                self.turns.push(TurnDraft {
                    participant: draft.participant.clone(),
                    turn: draft.turn.clone(),
                    ..TurnDraft::default()
                });
                self.turns.len() - 1
            }
        };
        let turn = &mut self.turns[index];
        let follows = turn.last_seq != 0 && draft.seq == turn.last_seq + 1;
        turn.last_seq = turn.last_seq.max(draft.seq);
        if draft.fresh {
            turn.gap = false;
            turn.segments.insert(draft.segment, (draft.kind, draft.text.clone()));
            return;
        }
        if turn.gap || !follows {
            turn.gap = true;
            return;
        }
        let entry = turn.segments.entry(draft.segment).or_insert((draft.kind, String::new()));
        entry.1.push_str(&draft.text);
    }

    pub(super) fn drop_turn(&mut self, participant: &str, turn: &str) {
        self.turns.retain(|t| !(t.participant == participant && t.turn == turn));
    }

    /// The posted message replaces its draft (same author and idempotency key).
    pub(super) fn on_message(&mut self, message: &Value) {
        let author = message.get("author").and_then(Value::as_str).unwrap_or("");
        let key = message.get("client_msg_id").and_then(Value::as_str).unwrap_or("");
        self.drop_turn(author, key);
    }

    /// A participant stopped typing: its turn ended, so its drafts go.
    pub(super) fn on_typing_off(&mut self, participant: &str) {
        self.turns.retain(|t| t.participant != participant);
    }

    #[cfg(test)]
    pub(super) fn is_empty(&self) -> bool {
        self.turns.iter().all(|t| t.segments.is_empty())
    }
}
