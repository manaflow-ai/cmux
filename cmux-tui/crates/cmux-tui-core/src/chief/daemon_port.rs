//! The conversation port, in process (plans/cmux-next/chief-mac.md section
//! 2, `ConversationPort`): the Chief's writes go straight to the local
//! conversation owner as `agent_mux`, and `conversation-changed` events come
//! from a mux event subscription. A "connection" is one subscription: it
//! starts with the default conversation (`daemon_connected`) and ends when
//! the subscription overflows or a store call fails, which the core sees as
//! `disconnected {daemon}`; the link connects again after the backoff.

use std::time::{Duration, Instant};

use cmux_chief::rules::{
    AGENT_MUX, CHIEF_CONVERSATION_TITLE, CHIEF_DISPLAY_NAME, DEFAULT_CONVERSATION_KEY,
    MUX_SESSION_NAME, USER_LOCAL,
};
use cmux_chief::{Effect, Input, Port};
use cmux_conversation::{AgentClass, Participant, ParticipantKind};

use super::actor::{Actor, Msg};
use crate::conversation_store::{ConversationEvent, ConversationRejected, MAX_PAGE_MESSAGES};
use crate::{MuxEvent, MuxEventReceiver};

/// The current subscription and the reconnect backoff.
pub(super) struct DaemonLink {
    generation: u64,
    receiver: Option<MuxEventReceiver>,
    retry_at: Option<Instant>,
    delay: Duration,
    initial: Duration,
    max: Duration,
    up_since: Option<Instant>,
}

impl DaemonLink {
    pub(super) fn new(initial: Duration, max: Duration) -> Self {
        Self {
            generation: 0,
            receiver: None,
            retry_at: None,
            delay: initial,
            initial,
            max,
            up_since: None,
        }
    }

    pub(super) fn is_current(&self, generation: u64) -> bool {
        self.receiver.is_some() && generation == self.generation
    }

    pub(super) fn retry_at(&self) -> Option<Instant> {
        self.retry_at
    }

    /// Ends the subscription (its forwarding thread returns).
    pub(super) fn close(&mut self) {
        if let Some(receiver) = self.receiver.take() {
            receiver.close();
        }
    }

    /// Ends the link and arms the reconnect. A link that lived longer than
    /// the backoff maximum starts the backoff over.
    fn lost(&mut self) {
        self.close();
        if self.up_since.take().is_some_and(|up| up.elapsed() > self.max) {
            self.delay = self.initial;
        }
        self.retry_at = Some(Instant::now() + self.delay);
        self.delay = (self.delay * 2).min(self.max);
    }
}

/// The default conversation's participants (the TypeScript host's `defaultParticipants`).
pub(super) fn default_participants(display_name: &str) -> Vec<Participant> {
    vec![
        Participant {
            id: USER_LOCAL.to_owned(),
            kind: ParticipantKind::Human,
            display_name: display_name.to_owned(),
            agent_class: None,
            acp_session: None,
        },
        Participant {
            id: AGENT_MUX.to_owned(),
            kind: ParticipantKind::Agent,
            display_name: CHIEF_DISPLAY_NAME.to_owned(),
            agent_class: Some(AgentClass::Mux),
            acp_session: Some(MUX_SESSION_NAME.to_owned()),
        },
    ]
}

/// The reject code of a refused store call, if it was a refusal.
fn reject_reason(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<ConversationRejected>().map(|rejected| rejected.0.code().to_owned())
}

impl Actor {
    /// Subscribes first (no event between the create and the subscription is
    /// lost), creates the default conversation as the local user, and feeds
    /// `daemon_connected`. A failure arms the reconnect.
    pub(super) fn daemon_connect(&mut self) {
        self.daemon.retry_at = None;
        self.daemon.generation += 1;
        let generation = self.daemon.generation;
        let receiver = self.mux.subscribe_conversations();
        if let Err(error) = spawn_forwarder(receiver.clone(), self.sender(), generation) {
            self.log(&format!("daemon: cannot subscribe: {error}"));
            receiver.close();
            self.daemon.lost();
            return;
        }
        self.daemon.receiver = Some(receiver);
        let participants = default_participants(&self.config.display_name);
        match self.mux.conversation_create_as(
            DEFAULT_CONVERSATION_KEY,
            USER_LOCAL,
            CHIEF_CONVERSATION_TITLE,
            &participants,
        ) {
            Ok(outcome) => {
                self.daemon.up_since = Some(Instant::now());
                self.log(&format!("daemon connected; conversation {}", outcome.summary.id));
                self.feed(Input::DaemonConnected { conversation: outcome.summary });
            }
            Err(error) => {
                self.log(&format!("daemon: default conversation: {error:#}"));
                self.daemon.lost();
            }
        }
    }

    /// The link ended: the core drops what it held for it; reconnect after the backoff.
    pub(super) fn daemon_lost(&mut self) {
        let was_up = self.daemon.receiver.is_some();
        self.daemon.lost();
        if was_up {
            self.feed(Input::Disconnected { port: Port::Daemon });
        }
    }

    /// Runs one conversation effect in process. A refusal is an input (an op
    /// result with the reason, or `fetch_refused`); any other failure ends
    /// the link, so the reconnect catches up again.
    pub(super) fn daemon_effect(&mut self, effect: Effect) {
        if self.daemon.receiver.is_none() {
            return;
        }
        let result = match effect {
            Effect::ConversationOp { conversation, idempotency_key, op } => {
                match self.mux.conversation_op_as(
                    &conversation,
                    &idempotency_key,
                    AGENT_MUX,
                    None,
                    &op,
                ) {
                    Ok(outcome) => Ok(Input::OpResult {
                        idempotency_key,
                        reason: None,
                        change: serde_json::from_value(outcome.result.change).ok(),
                    }),
                    Err(error) => match reject_reason(&error) {
                        Some(reason) => Ok(Input::OpResult {
                            idempotency_key,
                            reason: Some(reason),
                            change: None,
                        }),
                        None => Err(error),
                    },
                }
            }
            Effect::Typing { conversation, on } => {
                if let Err(error) = self.mux.conversation_typing_as(&conversation, AGENT_MUX, on) {
                    self.log(&format!(
                        "typing {} failed: {error:#}",
                        if on { "on" } else { "off" }
                    ));
                }
                return;
            }
            read => self.daemon_read(read),
        };
        match result {
            Ok(input) => self.feed(input),
            Err(error) => {
                self.log(&format!("daemon request failed: {error:#}; reconnecting"));
                self.daemon_lost();
            }
        }
    }

    fn daemon_read(&mut self, effect: Effect) -> anyhow::Result<Input> {
        let (conversation, read) = match effect {
            Effect::ListConversations => (
                None,
                self.mux
                    .with_conversations(|store| store.list())
                    .map(|conversations| Input::ConversationsListed { conversations }),
            ),
            Effect::FetchSnapshot { conversation, tail } => {
                let tail = tail.clamp(1, MAX_PAGE_MESSAGES);
                let read = self.mux.with_conversations(|store| store.snapshot(&conversation, tail));
                (
                    Some(conversation),
                    read.map(|(conversation, messages)| Input::Snapshot { conversation, messages }),
                )
            }
            Effect::FetchHistory { conversation, before_seq, limit } => {
                let limit = limit.clamp(1, MAX_PAGE_MESSAGES);
                let read = self
                    .mux
                    .with_conversations(|store| store.history(&conversation, before_seq, limit));
                let id = conversation.clone();
                (
                    Some(conversation),
                    read.map(|messages| Input::History { conversation: id, messages }),
                )
            }
            other => anyhow::bail!("not a conversation effect: {other:?}"),
        };
        read.or_else(|error| match reject_reason(&error) {
            Some(reason) => Ok(Input::FetchRefused { conversation, reason }),
            None => Err(error),
        })
    }
}

/// Forwards committed conversation changes to the actor until the
/// subscription closes; an overflow ends the link (the core catches up from
/// the read cursors on the next connect).
fn spawn_forwarder(
    receiver: MuxEventReceiver,
    sender: std::sync::mpsc::Sender<Msg>,
    link: u64,
) -> std::io::Result<()> {
    std::thread::Builder::new().name("chief-conversations".into()).spawn(move || {
        while let Ok(event) = receiver.recv() {
            if receiver.overflowed() {
                let _ = sender.send(Msg::DaemonLost { link });
                return;
            }
            let MuxEvent::Conversation(event) = event else { continue };
            let ConversationEvent::Changed { conversation, change, .. } = &*event else { continue };
            let Ok(change) = serde_json::from_value(change.clone()) else {
                // A change this core cannot read: the next catch-up reads the messages.
                let _ = sender.send(Msg::Log(format!("unreadable change in {conversation}")));
                continue;
            };
            let input = Input::ConversationChanged { conversation: conversation.clone(), change };
            if sender.send(Msg::Daemon { link, input }).is_err() {
                return;
            }
        }
    })?;
    Ok(())
}
