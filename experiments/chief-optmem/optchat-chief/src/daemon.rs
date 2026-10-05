//! The conversation owner's side (home.md section 2): the port the brain
//! writes through, and the link that connects with cmux-sdk, finds or
//! creates the Chief conversation exactly as mux/host does, binds as
//! `agent_mux`, subscribes, and reconnects after a loss.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux::raw::{
    Client, ClientConfig, ConversationBindRequest, ConversationCreateRequest,
    ConversationHistoryRequest, ConversationOpRequest, ConversationSnapshotRequest,
    ConversationTypingRequest, Error as SdkError, Event, Nullable, Optional, SubscribeRequest,
    SubscribeRequestTreeEvents,
};
use cmux_chief::rules::{AGENT_MUX, DEFAULT_CONVERSATION_KEY, MUX_SESSION_NAME, USER_LOCAL};
use cmux_conversation::{AgentClass, Change, Message, Op, Participant, ParticipantKind, Summary};
use serde_json::Value;

pub const CAPABILITY: &str = "local-conversations-v1";

/// A failed write.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OpError {
    /// The owner refused it; the text holds the reason code (`agent_rate`, ...).
    Rejected(String),
    /// The connection failed; the write may or may not have happened.
    Transport(String),
}

impl std::fmt::Display for OpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OpError::Rejected(r) => write!(f, "rejected: {r}"),
            OpError::Transport(e) => write!(f, "transport: {e}"),
        }
    }
}

/// The conversation operations the brain needs, on a connection bound as `agent_mux`.
pub trait ConversationPort: Send {
    fn snapshot(
        &mut self,
        conversation: &str,
        tail: u32,
    ) -> Result<(Summary, Vec<Message>), OpError>;
    fn history(
        &mut self,
        conversation: &str,
        before_seq: u64,
        limit: u32,
    ) -> Result<Vec<Message>, OpError>;
    /// Commits `op` as `agent_mux`; returns the change on success.
    fn op(&mut self, conversation: &str, key: &str, op: &Op) -> Result<Option<Change>, OpError>;
    fn typing(&mut self, conversation: &str, on: bool) -> Result<(), OpError>;
}

/// What the brain hears from the daemon.
pub enum DaemonEvent {
    /// Connected, created or found the conversation and subscribed; `reconnect`
    /// drops the connection so the link connects (and binds) again.
    Up {
        port: Box<dyn ConversationPort>,
        conversation: Summary,
        reconnect: Box<dyn Fn() + Send>,
    },
    Changed {
        conversation: String,
        change: Change,
    },
    Down,
    /// The daemon cannot host local conversations: the host cannot run.
    Fatal(String),
}

/// The participants of the Chief conversation, the same as mux/host's, so
/// the owner replays the same create (one conversation, the app's Chief tab).
pub fn participants(display_name: &str) -> Vec<Participant> {
    vec![
        Participant {
            id: USER_LOCAL.into(),
            kind: ParticipantKind::Human,
            display_name: display_name.into(),
            agent_class: None,
            acp_session: None,
        },
        Participant {
            id: AGENT_MUX.into(),
            kind: ParticipantKind::Agent,
            display_name: "mux".into(),
            agent_class: Some(AgentClass::Mux),
            acp_session: Some(MUX_SESSION_NAME.into()),
        },
    ]
}

/// The Mac user's full name (`id -F`), else the login name, as mux/host names user_local.
pub fn full_name() -> String {
    let out = std::process::Command::new("/usr/bin/id").arg("-F").output();
    if let Ok(out) = out
        && out.status.success()
    {
        let name = String::from_utf8_lossy(&out.stdout).trim().to_owned();
        if !name.is_empty() {
            return name;
        }
    }
    std::env::var("USER").unwrap_or_else(|_| "user".into())
}

/// The token file's text, trimmed; None when missing or empty.
pub fn read_token(file: Option<&std::path::Path>) -> Option<String> {
    let text = std::fs::read_to_string(file?).ok()?;
    let token = text.trim();
    (!token.is_empty()).then(|| token.to_owned())
}

fn sdk_error(error: SdkError) -> OpError {
    match error {
        SdkError::Command { message, .. } => OpError::Rejected(message),
        SdkError::Protocol { code, message, .. } => OpError::Rejected(format!("{code}: {message}")),
        other => OpError::Transport(other.to_string()),
    }
}

fn decode<T: serde::de::DeserializeOwned>(value: Value, what: &str) -> Result<T, OpError> {
    serde_json::from_value(value).map_err(|e| OpError::Transport(format!("{what}: {e}")))
}

/// The port over a cmux-sdk connection.
pub struct SdkConversations {
    client: Client,
}

impl ConversationPort for SdkConversations {
    fn snapshot(
        &mut self,
        conversation: &str,
        tail: u32,
    ) -> Result<(Summary, Vec<Message>), OpError> {
        let data = self
            .client
            .conversation_snapshot(ConversationSnapshotRequest {
                conversation: conversation.into(),
                tail,
            })
            .map_err(sdk_error)?;
        let summary = decode(
            data.get("conversation").cloned().unwrap_or(Value::Null),
            "snapshot summary",
        )?;
        let messages = decode(
            data.get("messages")
                .cloned()
                .unwrap_or(Value::Array(Vec::new())),
            "snapshot messages",
        )?;
        Ok((summary, messages))
    }

    fn history(
        &mut self,
        conversation: &str,
        before_seq: u64,
        limit: u32,
    ) -> Result<Vec<Message>, OpError> {
        let data = self
            .client
            .conversation_history(ConversationHistoryRequest {
                before_seq,
                conversation: conversation.into(),
                limit,
            })
            .map_err(sdk_error)?;
        decode(
            data.get("messages")
                .cloned()
                .unwrap_or(Value::Array(Vec::new())),
            "history",
        )
    }

    fn op(&mut self, conversation: &str, key: &str, op: &Op) -> Result<Option<Change>, OpError> {
        let op = serde_json::to_value(op).map_err(|e| OpError::Transport(e.to_string()))?;
        let data = self
            .client
            .conversation_op(ConversationOpRequest {
                actor: Optional::Value(AGENT_MUX.into()),
                conversation: conversation.into(),
                idempotency_key: key.into(),
                op: Nullable::value(op),
                transaction: Optional::Missing,
            })
            .map_err(sdk_error)?;
        Ok(data
            .get("change")
            .and_then(|c| serde_json::from_value(c.clone()).ok()))
    }

    fn typing(&mut self, conversation: &str, on: bool) -> Result<(), OpError> {
        self.client
            .conversation_typing(ConversationTypingRequest {
                actor: Optional::Value(AGENT_MUX.into()),
                conversation: conversation.into(),
                on,
            })
            .map(|_| ())
            .map_err(sdk_error)
    }
}

enum ConnectError {
    Missing(String),
    Other(String),
}

/// How the link connects.
#[derive(Clone, Debug)]
pub struct LinkConfig {
    pub socket: PathBuf,
    pub token_file: Option<PathBuf>,
    pub display_name: String,
}

fn connect(config: &LinkConfig) -> Result<(Client, Summary, cmux::raw::Stream), ConnectError> {
    let other = |e: SdkError| ConnectError::Other(e.to_string());
    let sdk = ClientConfig::from_socket_path(&config.socket);
    let mut client = Client::connect(sdk.clone()).map_err(other)?;
    // Read leniently (only the capabilities matter here), as mux/host does,
    // so a daemon that adds or drops other identify fields still connects.
    let mut identify = serde_json::Map::new();
    identify.insert("cmd".into(), Value::String("identify".into()));
    let identity = client.request_raw(identify).map_err(other)?;
    let data = identity.get("data").cloned().unwrap_or(Value::Null);
    let capable = data
        .get("capabilities")
        .and_then(Value::as_array)
        .is_some_and(|caps| caps.iter().any(|c| c.as_str() == Some(CAPABILITY)));
    if !capable {
        let text = |k: &str| {
            data.get(k)
                .map(|v| v.to_string())
                .unwrap_or_else(|| "?".into())
        };
        return Err(ConnectError::Missing(format!(
            "daemon at {} ({} {}) lacks {CAPABILITY}",
            config.socket.display(),
            text("app"),
            text("version")
        )));
    }
    let participants =
        serde_json::to_value(participants(&config.display_name)).expect("participants");
    let created = client
        .conversation_create(ConversationCreateRequest {
            actor: Optional::Value(USER_LOCAL.into()),
            idempotency_key: DEFAULT_CONVERSATION_KEY.into(),
            participants: Nullable::value(participants),
            title: "mux".into(),
        })
        .map_err(other)?;
    let summary: Summary =
        serde_json::from_value(created.get("conversation").cloned().unwrap_or(Value::Null))
            .map_err(|e| ConnectError::Other(format!("conversation-create: {e}")))?;
    // Read at every connect: the app mints a new token on each launch.
    match read_token(config.token_file.as_deref()) {
        Some(token) => {
            client
                .conversation_bind(ConversationBindRequest {
                    participant: AGENT_MUX.into(),
                    token,
                })
                .map_err(other)?;
        }
        None => {
            return Err(ConnectError::Other(
                "MUX_AGENT_TOKEN_FILE is missing or empty".into(),
            ));
        }
    }
    // Events arrive on their own connection; subscribing before the brain's
    // snapshot means no change falls between the two.
    let stream = client
        .subscribe(SubscribeRequest {
            surface: Optional::Missing,
            tree_events: Optional::Value(SubscribeRequestTreeEvents::Deltas),
        })
        .map_err(other)?;
    Ok((client, summary, stream))
}

/// Runs the daemon connection loop on its own thread.
pub fn spawn_link(
    config: LinkConfig,
    sink: Arc<dyn Fn(DaemonEvent) + Send + Sync>,
    log: Arc<dyn Fn(&str) + Send + Sync>,
) {
    std::thread::Builder::new()
        .name("daemon-link".into())
        .spawn(move || {
            let mut delay = Duration::from_millis(500);
            loop {
                let started = Instant::now();
                match connect(&config) {
                    Ok((client, conversation, mut stream)) => {
                        log(&format!(
                            "daemon connected; conversation {}",
                            conversation.id
                        ));
                        let closer = stream.closer();
                        sink(DaemonEvent::Up {
                            port: Box::new(SdkConversations { client }),
                            conversation,
                            reconnect: Box::new(move || closer.close()),
                        });
                        loop {
                            match stream.recv() {
                                Ok(Event::ConversationChanged(event)) => {
                                    let change = event
                                        .change
                                        .into_option()
                                        .and_then(|c| serde_json::from_value(c).ok());
                                    if let Some(change) = change {
                                        sink(DaemonEvent::Changed {
                                            conversation: event.conversation,
                                            change,
                                        });
                                    }
                                }
                                Ok(other) if other.wire_name() == Some("overflow") => {
                                    // Fell behind: the reconnect catches up from the read cursor.
                                    log("daemon subscription overflow; resubscribing");
                                    break;
                                }
                                Ok(_) => {}
                                Err(SdkError::Timeout(_)) => {}
                                Err(e) => {
                                    log(&format!("daemon connection closed: {e}"));
                                    break;
                                }
                            }
                        }
                        sink(DaemonEvent::Down);
                    }
                    Err(ConnectError::Missing(why)) => {
                        sink(DaemonEvent::Fatal(why));
                        return;
                    }
                    Err(ConnectError::Other(e)) => log(&format!("daemon: {e}")),
                }
                if started.elapsed() > Duration::from_secs(30) {
                    delay = Duration::from_millis(500);
                }
                std::thread::sleep(delay);
                delay = (delay * 2).min(Duration::from_secs(30));
            }
        })
        .expect("spawn daemon link");
}
