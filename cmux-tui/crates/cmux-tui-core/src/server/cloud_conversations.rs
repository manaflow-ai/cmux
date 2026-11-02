//! Raw protocol handlers for the cloud conversations proxy
//! (`cloud-conversations-v1`, plans/cmux-next/home-cloud-proxy.md). The
//! Durable Objects own the data; these handlers forward to the daemon's cloud
//! link on trusted local connections only. Commands that call the cloud run
//! on a worker thread, so a slow cloud never delays the connection's other
//! requests; their replies are matched by `id`.

use crate::panic_free::JsonFields;
use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Value, json};

use super::{Command, MessageWriter, Mux, Response, handle_command_with_cancellation, responses};
use crate::cloud_conversations::{
    CloudConversations, CloudError, InboxOpRequest, OpRequest, SessionParams, Target,
};
use crate::conversation_store::LOCAL_USER;

pub(super) use crate::cloud_conversations::CLOUD_CONVERSATIONS_CAPABILITY as CAPABILITY;
pub(super) use crate::cloud_conversations::CLOUD_SELFHOST_CAPABILITY as SELFHOST_CAPABILITY;

/// Advertised with `cloud-conversations-v1`: only the verified cmux app
/// connection sets or clears the human's lease and sends `origin: "user"`
/// (home-cloud-proxy.md section 3, cmux#13742).
pub(super) const APP_ONLY_LEASE_CAPABILITY: &str = "cloud-lease-app-only-v1";

/// A WebSocket client that authenticated with a pairing-store credential (a
/// human-approved pairing, or the page credential the verified app asked for
/// with `page-credential`) is the person: it uses the human's lease that the
/// verified app set (reads, subscribes, sends with `origin: "user"`, the
/// lease's cloud events). The static or file token never is (any same-user
/// process can read the file; the lease stays the app's, cmux#13742). It
/// never sets or clears a lease, and never uses a lease another connection
/// set (a headless brain's chief token).
/// (cx-hnmbt, ARCHITECTURE.md section 14.)
pub(super) const WS_CLOUD_CAPABILITY: &str = "ws-cloud-conversations-v1";
/// A Cloud Chief's runs through the daemon: `cloud-conversation-runs`,
/// `cloud-conversation-run` (the Chief brain's run reads) and the
/// `cloud-conversation-run-changed` event of a subscribed conversation, for a
/// connection that echoes `conversation-runs-v1` (advertised with
/// `cloud-conversations-v1`).
pub(super) const CLOUD_RUNS_CAPABILITY: &str = "cloud-conversation-runs-v1";
/// A Cloud Chief's live frames through the daemon (`chief-live-v1` on the
/// Cloud socket): the `cloud-conversation-live` event of a subscribed
/// conversation, for a connection that echoes `chief-live-v1`, and
/// `cloud-conversation-live`, which asks the owner for its `run.live`
/// snapshot (advertised with `cloud-conversations-v1`).
pub(super) const CLOUD_LIVE_CAPABILITY: &str = "cloud-chief-live-v1";
/// `cloud-conversation-typing`: the owner's ephemeral `typing` frame
/// through the daemon, and the `cloud-conversation-typing` event (the owner's
/// `conversation-typing` broadcast of a subscribed conversation) for a
/// connection that echoes it (advertised with `cloud-conversations-v1`).
pub(super) const CLOUD_TYPING_CAPABILITY: &str = "cloud-conversation-typing-v1";
/// `cloud-conversation-presence`: the owner's ephemeral `presence.set` frame
/// (the person views the conversation while any client of the daemon does)
/// through the daemon, and the `cloud-conversation-presence` event (the
/// owner's `conversation-presence` set of a subscribed conversation) for a
/// connection that echoes it (advertised with `cloud-conversations-v1`).
pub(super) const CLOUD_PRESENCE_CAPABILITY: &str = "cloud-conversation-presence-v1";

/// Whether `client` is the verified cmux app (the `frontend` actor: a
/// role-main Unix connection whose code signature or install key was
/// proved in `client-hello`), the same check the feed handoff uses.
fn is_app(mux: &Mux, client: u64) -> bool {
    matches!(super::origin_gate::connection_actor(mux, client), crate::Actor::Frontend { .. })
}

/// Whether `client` is a WebSocket connection that authenticated with a
/// pairing-store credential (`ws-cloud-conversations-v1`), never a Unix one.
fn is_websocket_person(mux: &Mux, client: u64) -> bool {
    mux.control_clients.is_websocket_person(client)
}

/// Whether `client` acts as the person with the app's lease: the verified
/// app, or an authenticated WebSocket client (`ws-cloud-conversations-v1`).
pub(super) fn is_person(mux: &Mux, client: u64) -> bool {
    is_app(mux, client) || is_websocket_person(mux, client)
}

/// `origin: "user"` says the human acted (in the app, or in a page that is
/// the person's own authenticated client); any other connection is
/// refused, never silently re-tagged.
fn check_origin(mux: &Mux, client: u64, origin: Option<&str>) -> anyhow::Result<()> {
    if origin != Some("user") || is_person(mux, client) {
        return Ok(());
    }
    Err(CloudError::Rejected {
        code: "forbidden".into(),
        message: "origin \"user\" requires the verified cmux app connection or the person's authenticated page"
            .into(),
        retryable: false,
    }
    .into())
}

/// `cloud-session-set`: the app's cloud session lease. The token moves into
/// the cloud link's zeroizing buffer and is never echoed or logged. With
/// `auth: "tailscale"` (`cloud-selfhost-v1`) the lease names a self-hosted
/// chat server on the tailnet and carries no token and no expiry.
#[derive(Deserialize)]
pub(super) struct SessionSetParams {
    api_base_url: String,
    #[serde(default)]
    auth: Option<String>,
    #[serde(default)]
    access_token: String,
    #[serde(default)]
    expires_at: u64,
    #[serde(default)]
    client_version: Option<String>,
}

/// `cloud-conversation-op`: one cloud op tagged by `kind`.
#[derive(Deserialize)]
pub(super) struct OpParams {
    #[serde(default)]
    conversation: Option<String>,
    idempotency_key: String,
    #[serde(default)]
    origin: Option<String>,
    op: Value,
}

impl From<OpParams> for OpRequest {
    fn from(params: OpParams) -> Self {
        let OpParams { conversation, idempotency_key, origin, op } = params;
        OpRequest { conversation, idempotency_key, origin, op }
    }
}

/// `cloud-inbox-op` (`conversation-inbox-state-v1`): the person's own pin or
/// "marked unread" of one cloud conversation (UserDO `inbox.pin`,
/// `inbox.mark_unread`).
#[derive(Deserialize)]
pub(super) struct InboxOpParams {
    conversation: String,
    idempotency_key: String,
    op: Value,
}

impl From<InboxOpParams> for InboxOpRequest {
    fn from(params: InboxOpParams) -> Self {
        let InboxOpParams { conversation, idempotency_key, op } = params;
        InboxOpRequest { conversation, idempotency_key, op }
    }
}

/// `cloud-inbox-list`.
#[derive(Deserialize)]
pub(super) struct InboxListParams {
    #[serde(default)]
    limit: Option<u32>,
    #[serde(default)]
    include_archived: bool,
    /// The `next_cursor` of the page before (absent: the first page).
    #[serde(default)]
    cursor: Option<String>,
}

/// `cloud-conversation-snapshot`.
#[derive(Deserialize)]
pub(super) struct SnapshotParams {
    conversation: String,
    tail: u32,
}

/// `cloud-conversation-history`.
#[derive(Deserialize)]
pub(super) struct HistoryParams {
    conversation: String,
    before_seq: u64,
    limit: u32,
}

/// `cloud-conversation-thread` (`conversation-thread-v1`).
#[derive(Deserialize)]
pub(super) struct ThreadParams {
    conversation: String,
    root: String,
    #[serde(default)]
    after_seq: Option<u64>,
    #[serde(default)]
    limit: Option<u32>,
}

/// `cloud-conversation-runs`: a Chief's runs in a conversation, newest first.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct RunsParams {
    conversation: String,
    agent: String,
    #[serde(default)]
    before_started_at: Option<u64>,
    #[serde(default)]
    limit: Option<u32>,
}

/// `cloud-conversation-run`: one run of a Chief and its steps after `after_seq`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct RunParams {
    conversation: String,
    agent: String,
    run: String,
    #[serde(default)]
    after_seq: Option<u64>,
}

/// `cloud-participant-avatar-get`: a Cloud participant's picture.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct AvatarParams {
    participant_id: String,
    /// A conversation the person and the participant are both in: Cloud
    /// answers another participant's picture only with one.
    #[serde(default)]
    conversation: Option<String>,
}

/// `cloud-conversation-subscribe` / `cloud-conversation-unsubscribe`.
#[derive(Deserialize)]
pub(super) struct TargetParams {
    conversation: String,
}

/// `cloud-conversation-typing`.
#[derive(Deserialize)]
pub(super) struct TypingParams {
    conversation: String,
    on: bool,
}

/// `cloud-conversation-presence`.
#[derive(Deserialize)]
pub(super) struct PresenceParams {
    conversation: String,
    viewing: bool,
}

/// `cloud-mux-subscribe` / `cloud-mux-unsubscribe` / `cloud-requests-list`: no
/// fields at all, so a client cannot name a chief (the queue is the lease
/// token's) or another person (the requests are the lease's).
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct NoParams {
    // No fields: the queue is the lease token's chief.
}

/// `cloud-mux-ack`: ids only. No `agent` field: the chief is the lease's
/// (an unknown field is refused, so a client cannot name another chief).
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct MuxAckParams {
    conversation: String,
    seq: u64,
}

/// The stable `reason` of a cloud error (the reply's `reason` field).
pub(super) fn error_reason(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<CloudError>().and_then(CloudError::reason)
}

/// The `error_code` of a cloud error.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    let cloud = error.downcast_ref::<CloudError>()?;
    if let CloudError::Rejected { code, .. } = cloud
        && code.starts_with("cloud_environment.")
    {
        return Some(code.clone());
    }
    cloud.error_code().map(str::to_string)
}

/// The reply's `retryable` flag of a cloud error.
pub(super) fn error_retryable(error: &anyhow::Error) -> Option<bool> {
    error.downcast_ref::<CloudError>().and_then(CloudError::retryable)
}

fn service(mux: &Mux, client: u64) -> anyhow::Result<&CloudConversations> {
    anyhow::ensure!(
        mux.control_clients.is_unix(client) || is_websocket_person(mux, client),
        "cloud conversations require a trusted local connection or a paired page"
    );
    // The lease is the human's cloud authority. A connection that bound
    // itself to a conversation agent acts as that agent, never as the human.
    anyhow::ensure!(
        mux.conversation_principal(client) == LOCAL_USER,
        "cloud conversations are refused on a connection bound to a conversation agent"
    );
    mux.cloud_conversations()
        .ok_or_else(|| anyhow::anyhow!("cloud conversations are not available in this daemon"))
}

/// The service for a command that uses the lease. While the verified cmux
/// app holds the lease, it is the human's: only the app may read, send or
/// subscribe with it (cmux#13742). `cloud-session-status` and the
/// unsubscribes use no lease and stay open.
pub(super) fn lease_user(mux: &Mux, client: u64) -> anyhow::Result<&CloudConversations> {
    let service = service(mux, client)?;
    // A page uses only the human's lease (the app's), never another one.
    if is_websocket_person(mux, client) {
        return if service.app_holds_lease() {
            Ok(service)
        } else {
            Err(CloudError::SignedOut.into())
        };
    }
    let app = is_app(mux, client);
    // The app never uses a lease another connection set (P2-2): it is signed
    // out until it leases its own session.
    if app && !service.app_holds_lease() {
        return Err(CloudError::SignedOut.into());
    }
    if service.app_holds_lease() && !app {
        return Err(CloudError::Rejected {
            code: "forbidden".into(),
            message: "the cloud session lease belongs to the verified cmux app connection; \
                      other connections cannot use it"
                .into(),
            retryable: false,
        }
        .into());
    }
    Ok(service)
}

/// Setting or clearing a lease stays on the Unix socket (local admin).
fn lease_holder(mux: &Mux, client: u64) -> anyhow::Result<&CloudConversations> {
    anyhow::ensure!(
        mux.control_clients.is_unix(client),
        "cloud-session-set and cloud-session-clear require a trusted local connection"
    );
    service(mux, client)
}

pub(super) fn session_set(
    mux: &Mux,
    client: u64,
    params: SessionSetParams,
) -> anyhow::Result<Value> {
    let SessionSetParams { api_base_url, auth, access_token, expires_at, client_version } = params;
    let lease = SessionParams { api_base_url, auth, access_token, expires_at, client_version };
    Ok(lease_holder(mux, client)?.set_session_by(lease, is_app(mux, client))?)
}

pub(super) fn session_clear(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    Ok(lease_holder(mux, client)?.clear_session_by(is_app(mux, client))?)
}

/// `cloud-session-status`. For the person's own clients (the app, a page)
/// with the app's lease it also names `participant`: the person's Worker
/// user id (backend `userIdFor`: `user_` and the first 20 hex digits of
/// sha256("stack:<project>:<stack user id>")), so a page knows which
/// participant of a cloud conversation is the person. Never the token.
pub(super) fn session_status(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    let service = service(mux, client)?;
    let person = is_person(mux, client);
    if person && !service.app_holds_lease() {
        return Ok(json!({"state": "signed_out"}));
    }
    let mut status = service.session_status();
    if person && let Some((account, project)) = service.lease_person() {
        status.insert("participant", json!(worker_user_id(&project, &account)));
    }
    // A self-hosted server names the person itself (`cloud-selfhost-info`).
    if person && let Some((_, Some(user))) = service.lease_selfhost() {
        status.insert("participant", json!(user));
    }
    Ok(status)
}

/// `cloud-selfhost-info` (`cloud-selfhost-v1`): the self-hosted server's
/// `GET /v1/selfhost/info` (`{kind, user_id, login, display_name,
/// server_name}`); the person's user id becomes the lease's account.
pub(super) fn selfhost_info(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    Ok(lease_user(mux, client)?.selfhost_info()?)
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct EnvironmentParams {
    pub action: String,
    pub params: Value,
    pub platform_origin: String,
    pub access_token: String,
}

impl Drop for EnvironmentParams {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.access_token.zeroize();
    }
}

// PATCH params can carry write-only secrets. Never include them in command diagnostics.
impl std::fmt::Debug for EnvironmentParams {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EnvironmentParams")
            .field("action", &self.action)
            .field("params", &"[redacted]")
            .field("access_token", &"[redacted]")
            .finish()
    }
}

/// Only the verified native app may forward its platform origin and install token.
pub(super) fn environment(
    mux: &Mux,
    client: u64,
    params: EnvironmentParams,
) -> anyhow::Result<Value> {
    if !is_app(mux, client) {
        return Err(CloudError::Rejected {
            code: "forbidden".into(),
            message: "cloud-environment requires the verified cmux app connection".into(),
            retryable: false,
        }
        .into());
    }
    Ok(service(mux, client)?.environment(
        &params.action,
        &params.params,
        &params.platform_origin,
        &params.access_token,
    )?)
}

/// The Worker's user id for a Stack user of a Stack project (backend
/// domains/user.ts `userIdFor`).
fn worker_user_id(project: &str, account: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(format!("stack:{project}:{account}").as_bytes());
    let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("user_{}", hex.get(..20).unwrap_or(&hex))
}

pub(super) fn inbox_list(mux: &Mux, client: u64, params: InboxListParams) -> anyhow::Result<Value> {
    Ok(lease_user(mux, client)?.inbox_list(
        params.limit,
        params.include_archived,
        params.cursor.as_deref(),
    )?)
}

/// `cloud-requests-list`: the person's open message requests (`home.requests.list`).
pub(super) fn requests_list(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    Ok(lease_user(mux, client)?.requests_list()?)
}

pub(super) fn snapshot(mux: &Mux, client: u64, params: SnapshotParams) -> anyhow::Result<Value> {
    Ok(lease_user(mux, client)?.snapshot(&params.conversation, params.tail)?)
}

pub(super) fn history(mux: &Mux, client: u64, params: HistoryParams) -> anyhow::Result<Value> {
    let HistoryParams { conversation, before_seq, limit } = params;
    Ok(lease_user(mux, client)?.history(&conversation, before_seq, limit)?)
}

pub(super) fn thread(mux: &Mux, client: u64, params: ThreadParams) -> anyhow::Result<Value> {
    let ThreadParams { conversation, root, after_seq, limit } = params;
    Ok(lease_user(mux, client)?.thread(&conversation, &root, after_seq, limit)?)
}

pub(super) fn runs(mux: &Mux, client: u64, params: RunsParams) -> anyhow::Result<Value> {
    let RunsParams { conversation, agent, before_started_at, limit } = params;
    Ok(lease_user(mux, client)?.chief_runs(&agent, &conversation, before_started_at, limit)?)
}

pub(super) fn run(mux: &Mux, client: u64, params: RunParams) -> anyhow::Result<Value> {
    let RunParams { conversation, agent, run, after_seq } = params;
    Ok(lease_user(mux, client)?.chief_run(&agent, &conversation, &run, after_seq)?)
}

pub(super) fn participant_avatar(
    mux: &Mux,
    client: u64,
    params: AvatarParams,
) -> anyhow::Result<Value> {
    Ok(lease_user(mux, client)?
        .participant_avatar(&params.participant_id, params.conversation.as_deref())?)
}

pub(super) fn op(mux: &Mux, client: u64, params: OpParams) -> anyhow::Result<Value> {
    let service = lease_user(mux, client)?;
    check_origin(mux, client, params.origin.as_deref())?;
    Ok(service.op(&OpRequest::from(params))?)
}

/// The person's own list state: only the person's clients (the verified
/// app, an authenticated page) write it, never a brain on its chief lease.
pub(super) fn inbox_op(mux: &Mux, client: u64, params: InboxOpParams) -> anyhow::Result<Value> {
    let service = lease_user(mux, client)?;
    check_person(mux, client)?;
    Ok(service.inbox_op(&InboxOpRequest::from(params))?)
}

fn check_person(mux: &Mux, client: u64) -> anyhow::Result<()> {
    if is_person(mux, client) {
        return Ok(());
    }
    Err(CloudError::Rejected {
        code: "forbidden".into(),
        message: "cloud-inbox-op requires the verified cmux app connection or the person's authenticated page"
            .into(),
        retryable: false,
    }
    .into())
}

pub(super) fn subscribe(
    mux: &Mux,
    client: u64,
    target: Option<TargetParams>,
) -> anyhow::Result<Value> {
    let target = target.map_or(Target::Inbox, |params| Target::Conversation(params.conversation));
    Ok(lease_user(mux, client)?.subscribe(client, target)?)
}

/// `cloud-conversation-live`: the subscriber asks for the owner's
/// `run.live` snapshot; it arrives as a `cloud-conversation-live` event.
pub(super) fn live(mux: &Mux, client: u64, params: TargetParams) -> anyhow::Result<Value> {
    Ok(lease_user(mux, client)?.request_live(client, &params.conversation)?)
}

/// `cloud-conversation-typing`: the lease's participant is typing or
/// stopped, as the owner's `typing` frame on the shared socket.
pub(super) fn typing(mux: &Mux, client: u64, params: TypingParams) -> anyhow::Result<Value> {
    Ok(lease_user(mux, client)?.typing(client, &params.conversation, params.on)?)
}

/// `cloud-conversation-presence`: the connection views the conversation or
/// stopped, as the owner's `presence.set` frame on the shared socket.
pub(super) fn presence(mux: &Mux, client: u64, params: PresenceParams) -> anyhow::Result<Value> {
    Ok(lease_user(mux, client)?.presence(client, &params.conversation, params.viewing)?)
}

pub(super) fn unsubscribe(
    mux: &Mux,
    client: u64,
    target: Option<TargetParams>,
) -> anyhow::Result<Value> {
    let target = target.map_or(Target::Inbox, |params| Target::Conversation(params.conversation));
    service(mux, client)?.unsubscribe(client, &target);
    Ok(json!({}))
}

/// `cloud-mux-subscribe`: the lease's own chief's wake queue.
pub(super) fn mux_subscribe(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    let service = lease_user(mux, client)?;
    Ok(service.subscribe(client, service.mux_target()?)?)
}

pub(super) fn mux_unsubscribe(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    let service = service(mux, client)?;
    if let Ok(target) = service.mux_target() {
        service.unsubscribe(client, &target);
    }
    Ok(json!({}))
}

pub(super) fn mux_ack(mux: &Mux, client: u64, params: MuxAckParams) -> anyhow::Result<Value> {
    Ok(lease_user(mux, client)?.mux_ack(&params.conversation, params.seq)?)
}

/// Whether `client`'s event stream carries cloud events (P2-1 of the
/// cmux#13742 review): while the app holds the lease, only the person's
/// own clients' (the app, an authenticated page); a page never gets the
/// events of another connection's lease.
pub(super) fn delivers(mux: &Mux, client: u64) -> bool {
    mux.cloud_conversations().is_some_and(|service| {
        if mux.control_clients.is_unix(client) {
            service.delivers_to(is_app(mux, client))
        } else {
            is_websocket_person(mux, client) && service.app_holds_lease()
        }
    })
}

/// Whether `cmd` calls the cloud and should leave the request loop.
pub(super) fn is_network(cmd: &Command) -> bool {
    // An upload's chunks and cancel stay local (the store only); begin and
    // commit call the cloud.
    if let Command::CloudAttachmentUpload(params) = cmd {
        return params.op == "begin" || params.op == "commit";
    }
    // The Home rows read the Cloud inbox unless only the local rows are asked.
    if let Command::HomeInbox(params) = cmd {
        return params.asks_cloud();
    }
    matches!(
        cmd,
        Command::CloudInboxList(_)
            | Command::CloudRequestsList(_)
            | Command::CloudSelfhostInfo(_)
            | Command::CloudEnvironment(_)
            | Command::CloudConversationSnapshot(_)
            | Command::CloudConversationHistory(_)
            | Command::CloudConversationThread(_)
            | Command::CloudConversationRuns(_)
            | Command::CloudConversationRun(_)
            | Command::CloudParticipantAvatarGet(_)
            | Command::CloudConversationOp(_)
            | Command::CloudInboxOp(_)
            | Command::CloudMuxAck(_)
            | Command::CloudAttachmentRead(_)
            | Command::CloudAttachmentLink(_)
    )
}

/// The target of a `cloud-*-subscribe` command.
pub(super) fn subscribe_target(mux: &Mux, cmd: &Command) -> Option<Target> {
    match cmd {
        Command::CloudInboxSubscribe => Some(Target::Inbox),
        Command::CloudMuxSubscribe(_) => mux.cloud_conversations()?.mux_target().ok(),
        Command::CloudConversationSubscribe(params) => {
            Some(Target::Conversation(params.conversation.clone()))
        }
        _ => None,
    }
}

/// Answers a subscribe with the shared socket's current state, then emits
/// that state as a `cloud-subscription-state` event. A reply travels on the
/// connection's control queue and events on its event stream, so a state
/// change that raced the reply may be written before it; the event queued
/// after the reply always follows it, and every later change follows too.
pub(super) fn subscribe_then_announce(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    cmd: Command,
    target: Target,
    writer: &MessageWriter,
) -> bool {
    let result = handle_command_with_cancellation(mux, client, cmd, writer, None);
    let subscribed = result.is_ok();
    let sent = send(writer, id, result);
    if subscribed && let Some(service) = mux.cloud_conversations() {
        service.announce_state(&target);
    }
    sent
}

/// Answers a network command from a worker thread. Trust, availability and
/// op shape are checked first on the request loop, so those errors answer
/// at once and nothing leaves a refused connection.
pub(super) fn start(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    cmd: Command,
    writer: &MessageWriter,
) -> bool {
    let precheck = || {
        if matches!(&cmd, Command::CloudEnvironment(_)) {
            if !is_app(mux, client) {
                return Err(CloudError::Rejected {
                    code: "forbidden".into(),
                    message: "cloud-environment requires the verified cmux app connection".into(),
                    retryable: false,
                }
                .into());
            }
            return Ok(service(mux, client)?.begin_request()?);
        }
        lease_user(mux, client).and_then(|service| {
            if let Command::CloudConversationOp(params) = &cmd {
                check_origin(mux, client, params.origin.as_deref())?;
                service.check_op(&OpRequest {
                    conversation: params.conversation.clone(),
                    idempotency_key: params.idempotency_key.clone(),
                    origin: params.origin.clone(),
                    op: params.op.clone(),
                })?;
            }
            if let Command::CloudInboxOp(params) = &cmd {
                check_person(mux, client)?;
                service.check_inbox_op(&InboxOpRequest {
                    conversation: params.conversation.clone(),
                    idempotency_key: params.idempotency_key.clone(),
                    op: params.op.clone(),
                })?;
            }
            Ok(service.begin_request()?)
        })
    };
    // The Home rows never fail for the Cloud: their worker takes its own lease
    // and request slot, and without them carries the local rows.
    let permit = if matches!(cmd, Command::HomeInbox(_)) {
        None
    } else {
        match precheck() {
            Ok(permit) => Some(permit),
            Err(error) => return send(writer, id, Err(error)),
        }
    };
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new().name("mux-cloud-request".into()).spawn(move || {
        let _permit = permit;
        let result =
            handle_command_with_cancellation(&worker_mux, client, cmd, &worker_writer, None);
        send(&worker_writer, worker_id, result);
    });
    match spawned {
        Ok(_) => true,
        Err(error) => send(
            writer,
            id,
            Err(CloudError::Unavailable(format!("request thread: {error}")).into()),
        ),
    }
}

fn send(writer: &MessageWriter, id: Option<Value>, result: anyhow::Result<Value>) -> bool {
    match result {
        Ok(data) => responses::send_response(
            writer,
            Response {
                id,
                ok: true,
                data: Some(data),
                error: None,
                error_code: None,
                error_delivery: None,
            },
        ),
        Err(error) => responses::send_response_with_details(
            writer,
            Response {
                id,
                ok: false,
                data: None,
                error: Some(error.to_string()),
                error_code: error_code(&error),
                error_delivery: None,
            },
            error_reason(&error),
            error_retryable(&error),
            None,
        ),
    }
}

#[cfg(test)]
#[path = "cloud_conversation_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "cloud_lease_gate_tests.rs"]
mod lease_gate_tests;

#[cfg(test)]
#[path = "cloud_request_tests.rs"]
mod request_tests;

#[cfg(test)]
#[path = "cloud_selfhost_tests.rs"]
mod selfhost_tests;
