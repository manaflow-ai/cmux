//! The conversation owner's side (home.md section 2): the port the brain
//! writes through, and the link that connects with cmux-sdk, finds or
//! creates the Chief conversation exactly as mux/host does, binds as
//! `agent_mux`, subscribes, and reconnects after a loss.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux::raw::{
    Client, ClientConfig, ConversationAttachmentReadRequest, ConversationBindRequest,
    ConversationCreateRequest, ConversationHistoryRequest, ConversationListRequest,
    ConversationOpRequest, ConversationSnapshotRequest, ConversationTypingRequest,
    Error as SdkError, Event, Nullable, Optional, SubscribeRequest, SubscribeRequestTreeEvents,
};
use cmux_chief::rules::{
    AGENT_MUX, CHIEF_CONVERSATION_TITLE, CHIEF_DISPLAY_NAME, DEFAULT_CONVERSATION_KEY,
    MUX_SESSION_NAME, USER_LOCAL,
};
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
    /// One attachment variant (`original`, `preview`, `poster`) of `hash`,
    /// base64, in a single owner read of `bytes` (at most 4 MiB): an error
    /// when the owner has not sent all of it (`local-attachments-v1`).
    fn attachment(
        &mut self,
        conversation: &str,
        hash: &str,
        variant: &str,
        bytes: u64,
    ) -> Result<String, OpError> {
        let _ = (conversation, hash, variant, bytes);
        Err(OpError::Rejected("attachments_unsupported".into()))
    }
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

/// The participants of the Chief conversation, the same as the app's
/// (HomeService.mux, HomeChiefName.createRequest), so the owner replays the
/// app's create (one conversation, the app's Chief tab).
pub fn participants(display_name: &str) -> Vec<Participant> {
    vec![
        Participant {
            id: USER_LOCAL.into(),
            kind: ParticipantKind::Human,
            display_name: display_name.into(),
            agent_class: None,
            acp_session: None,
            person: None,
        },
        Participant {
            id: AGENT_MUX.into(),
            kind: ParticipantKind::Agent,
            display_name: CHIEF_DISPLAY_NAME.into(),
            agent_class: Some(AgentClass::Mux),
            acp_session: Some(MUX_SESSION_NAME.into()),
            person: None,
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

/// The SDK's generated wire struct as the brain's own type (cmux-conversation
/// is the owner's source of truth; the SDK mirrors it field for field).
fn rewire<S: serde::Serialize, T: serde::de::DeserializeOwned>(
    value: &S,
    what: &str,
) -> Result<T, OpError> {
    let json =
        serde_json::to_value(value).map_err(|e| OpError::Transport(format!("{what}: {e}")))?;
    decode(json, what)
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
        let summary = rewire(&data.conversation, "snapshot summary")?;
        let messages = rewire(&data.messages, "snapshot messages")?;
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
        rewire(&data.messages, "history")
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
        Ok(rewire(&data.change, "op change").ok())
    }

    fn attachment(
        &mut self,
        conversation: &str,
        hash: &str,
        variant: &str,
        bytes: u64,
    ) -> Result<String, OpError> {
        let data = self
            .client
            .conversation_attachment_read(ConversationAttachmentReadRequest {
                conversation: conversation.into(),
                hash: hash.into(),
                length: Optional::Value(bytes),
                offset: Optional::Value(0),
                variant: Optional::Value(variant.into()),
            })
            .map_err(sdk_error)?;
        if !data.eof {
            return Err(OpError::Rejected(
                "attachment_needs_more_than_one_read".into(),
            ));
        }
        Ok(data.data)
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
    /// The create request's title: the app's (localized) Chief name.
    pub title: String,
}

impl LinkConfig {
    /// The app's names for the create request: `MUX_USER_NAME` (the app's
    /// user name) and `MUX_CHIEF_TITLE` (its localized Chief title), else
    /// the Mac's full name and "Chief".
    pub fn names_from_env() -> (String, String) {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
        (
            var("MUX_USER_NAME").unwrap_or_else(full_name),
            var("MUX_CHIEF_TITLE").unwrap_or_else(|| CHIEF_CONVERSATION_TITLE.into()),
        )
    }
}

/// The Chief conversation among `conversations`, by the rule the app shares
/// (HomeChiefName.select, select_chief_conversation): the oldest conversation
/// with agent_mux, by created_at, then id.
pub fn select_chief(conversations: Vec<Summary>) -> Option<Summary> {
    conversations
        .into_iter()
        .filter(|c| c.participants.iter().any(|p| p.id == AGENT_MUX))
        .min_by(|a, b| (&a.created_at, &a.id).cmp(&(&b.created_at, &b.id)))
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
    // The app creates the Chief conversation when Home opens; answer in the
    // one it shows. Create it (with the app's exact request, so the owner
    // replays one conversation) only when none exists yet.
    let listed = client
        .conversation_list(ConversationListRequest {})
        .map_err(other)?;
    let listed: Vec<Summary> = rewire(&listed.conversations, "conversation-list")
        .map_err(|e| ConnectError::Other(e.to_string()))?;
    let summary = match select_chief(listed) {
        Some(found) => found,
        None => {
            let participants =
                serde_json::to_value(participants(&config.display_name)).expect("participants");
            let created = client
                .conversation_create(ConversationCreateRequest {
                    actor: Optional::Value(USER_LOCAL.into()),
                    idempotency_key: DEFAULT_CONVERSATION_KEY.into(),
                    participants: Nullable::value(participants),
                    title: config.title.clone(),
                })
                .map_err(other)?;
            rewire(&created.conversation, "conversation-create")
                .map_err(|e| ConnectError::Other(e.to_string()))?
        }
    };
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
