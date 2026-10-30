//! Raw protocol handlers for the local conversation owner
//! (`local-conversations-v1`, plans/cmux-next/home.md section 2). The store
//! commits each op in one transaction; `conversation-changed` is published
//! only after that commit and never for a replay. Rejects carry `error_code`
//! `conversation_rejected` and the reason code as the error text.

use crate::panic_free::JsonFields;
use std::sync::Arc;

use cmux_conversation::{Change, Op, Participant, Reject};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::remote_relay::participants::{device_id_refused, is_device_id};
use super::{Mux, MuxEvent, validate_client_transaction};
use crate::conversation_search::ConversationSearchRejected;
use crate::conversation_store::attachments::AttachmentRejected;
use crate::conversation_store::inbox::InboxOp;
use crate::conversation_store::runs::RunRejected;
use crate::conversation_store::{
    ConversationEvent, ConversationRejected, LOCAL_USER, MAX_PAGE_MESSAGES, OpOutcome,
};

/// The local conversation owner: the `conversation-*` commands and the
/// `conversation-changed` and `conversation-typing` events, on trusted local
/// connections only.
pub const LOCAL_CONVERSATIONS_CAPABILITY: &str = "local-conversations-v1";
/// `conversation-search` on the local conversation owner.
pub const CONVERSATION_SEARCH_CAPABILITY: &str = "conversation-search-v1";
/// `conversation-draft`: the v1 command of `conversation.draft` for a bound
/// agent connection (the Chief brain's link).
pub const CONVERSATION_DRAFT_CAPABILITY: &str = "conversation-draft-v1";
/// `conversation-draft` events on `subscribe` for a trusted local connection
/// that echoes this capability in `set-client-info` (the app's Home).
pub const CONVERSATION_DRAFT_EVENTS_CAPABILITY: &str = "conversation-draft-events-v1";
/// `thread_root` on `message.send` and on messages, and a send that moves
/// the sender's own read cursor (cx-59n8.2).
pub const CONVERSATION_THREADS_CAPABILITY: &str = "conversation-threads-v1";
/// `conversation-thread` (one thread, paged), `threads` root stats on
/// `conversation-snapshot` and `conversation-history`, and with
/// `cloud-conversations-v1` also `cloud-conversation-thread` (cx-59n8.6).
pub const CONVERSATION_THREAD_READ_CAPABILITY: &str = "conversation-thread-v1";
/// Threads nest without a limit (`reply_to` is the parent, `thread_root` the
/// top root; a reply to a thread reply joins its thread) and
/// `conversation-link-resolve` opens a message permalink.
pub const CONVERSATION_TREE_CAPABILITY: &str = "conversation-tree-v1";
/// Threads are objects: the `thread.update` op (title, status open or
/// resolved, owner) on the local owner and through `cloud-conversation-op`,
/// `Message.thread` on roots, and the thread object fields of
/// `ThreadSummary` (a reply after the resolution reopens the thread).
pub const CONVERSATION_THREAD_OBJECTS_CAPABILITY: &str = "conversation-thread-objects-v1";
/// The person's own list state of a conversation, beside the conversation
/// (a pin with its position, a "marked unread" flag): `conversation-inbox-op`
/// on the local owner, the `pinned`, `pin_position` and `marked_unread`
/// fields of the caller's `conversation-list` items, the
/// `conversation-inbox-changed` event on `subscribe` (to that participant's
/// connections only), and with `cloud-conversations-v1` also `cloud-inbox-op`
/// (the Cloud owner's `inbox.pin` and `inbox.mark_unread`).
pub const CONVERSATION_INBOX_STATE_CAPABILITY: &str = "conversation-inbox-state-v1";
/// The local conversation owner on an authenticated WebSocket connection
/// (static credential or approved pairing) as `user_local`, the same as on
/// the Unix socket: `conversation-*` commands, `conversation.*` operations
/// and the conversation events of `subscribe` (cmux#13742).
pub const WS_CONVERSATIONS_CAPABILITY: &str = "ws-conversations-v1";
/// `link_preview` message parts on the local conversation owner.
pub const LINK_PREVIEW_CAPABILITY: &str = "link-preview-v1";
/// `conversation-agent-token` and `conversation-bind` also take a person
/// (`user_<id>`, never `user_local` or a `remote_` device): a connection
/// becomes that person for its lifetime, so the other people of a shared
/// room (a team server, a seeded demo) reply in threads, react and type as
/// themselves. It acts as a human participant (answers questions, resets
/// the agent turn budget, wakes a Chief like an imported human message
/// does) and never as the owner: it cannot mint, import or use owner-only
/// commands, and only the owner's own connection mints the credential.
pub const CONVERSATION_PERSON_CREDENTIALS_CAPABILITY: &str = "conversation-person-credentials-v1";
/// `home-inbox`: the Home list rows the caller sees, derived by the owner
/// (kind, display name, unread count, preview, a Chief's live state, the
/// caller's pins and marks, list order), so every view shows the same list.
pub const HOME_INBOX_CAPABILITY: &str = "home-inbox-v1";

/// `conversation-create`: a retry with the same `idempotency_key` and request
/// returns the conversation it created.
#[derive(Deserialize)]
pub(super) struct CreateParams {
    idempotency_key: String,
    #[serde(default)]
    actor: Option<String>,
    title: String,
    participants: Value,
}

/// `conversation-snapshot`: the summary and the last `tail` (1-500) messages.
#[derive(Deserialize)]
pub(super) struct SnapshotParams {
    pub(super) conversation: String,
    pub(super) tail: u32,
}

/// `conversation-history`: up to `limit` (1-500) messages below `before_seq`.
#[derive(Deserialize)]
pub(super) struct HistoryParams {
    pub(super) conversation: String,
    pub(super) before_seq: u64,
    pub(super) limit: u32,
}

/// `conversation-thread`: root `root` and up to `limit` (1-500, default 50)
/// of its replies with seq above `after_seq` (default 0).
#[derive(Deserialize)]
pub(super) struct ThreadParams {
    conversation: String,
    root: String,
    #[serde(default)]
    after_seq: u64,
    #[serde(default)]
    limit: Option<u32>,
}

/// `conversation-link-resolve`: the conversation and message a permalink
/// names (`<scheme>://conversation/<id>[/message/<id>]`).
#[derive(Deserialize)]
pub(super) struct LinkResolveParams {
    url: String,
}

/// `home-inbox`: which owners' rows (`local`, `cloud`; default both). In the
/// app the local conversations' owner and the Cloud lease can be two daemons.
#[derive(Deserialize)]
pub(super) struct HomeInboxParams {
    #[serde(default)]
    owners: Option<Vec<String>>,
}

impl HomeInboxParams {
    /// Whether the rows include the Cloud inbox (a network read: it leaves
    /// the request loop like `cloud-inbox-list`).
    pub(super) fn asks_cloud(&self) -> bool {
        self.owners.as_ref().is_none_or(|owners| owners.iter().any(|owner| owner == "cloud"))
    }
}

/// `conversation-inbox-op`: the caller's own pin or "marked unread" of one
/// conversation (`op` is `{kind: "inbox.pin", pinned, position?}` or
/// `{kind: "inbox.mark_unread", unread}`).
#[derive(Deserialize)]
pub(super) struct InboxOpParams {
    conversation: String,
    op: Value,
}

/// Default page of `conversation-thread`.
const THREAD_PAGE: u32 = 50;

/// `conversation-op`: one op under a client idempotency key.
#[derive(Deserialize)]
pub(super) struct OpParams {
    pub(super) conversation: String,
    pub(super) idempotency_key: String,
    #[serde(default)]
    pub(super) actor: Option<String>,
    #[serde(default)]
    pub(super) transaction: Option<String>,
    pub(super) op: Value,
}

/// `conversation-search`: Home-only search, the shared read model
/// (`cmux_conversation::search`): a case-insensitive substring of the text of
/// the caller's conversations, newest first.
#[derive(Deserialize)]
pub(super) struct SearchParams {
    query: String,
    limit: u32,
}

/// `conversation-typing`: a typing indicator. Never stored.
#[derive(Deserialize)]
pub(super) struct TypingParams {
    pub(super) conversation: String,
    #[serde(default)]
    pub(super) actor: Option<String>,
    pub(super) on: bool,
}

/// `conversation-draft`: a draft of the bound agent's running reply.
#[derive(Deserialize)]
pub(super) struct DraftParams {
    conversation: String,
    turn: String,
    segment: u64,
    seq: u64,
    kind: String,
    text: String,
    fresh: bool,
    done: bool,
    #[serde(default)]
    truncated: Option<bool>,
    #[serde(default)]
    harness: Option<String>,
}

/// `conversation-bind`: become `participant` (an agent, or with
/// `conversation-person-credentials-v1` another person) for the rest of the
/// connection, proven by the token the local user minted for it.
#[derive(Deserialize)]
pub(super) struct BindParams {
    participant: String,
    token: String,
}

/// `conversation-agent-token`: mint the credential of `participant`, an agent
/// or another person (local user connections only).
#[derive(Deserialize)]
pub(super) struct AgentTokenParams {
    participant: String,
}

/// `conversation-import`: history moved from another store, appended once
/// with its own authors and times (conversation_import.rs). Trusted local
/// user connections only; never a remote or an agent-bound connection.
#[derive(Deserialize)]
pub(super) struct ImportParams {
    conversation: String,
    messages: Vec<crate::conversation_store::ImportedMessage>,
}

/// The actor of a write is the connection's principal, stamped by the owner.
/// A request may still name it; naming anyone else is refused.
fn resolve_actor(mux: &Mux, client: u64, declared: Option<String>) -> anyhow::Result<String> {
    let principal = mux.conversation_principal(client);
    if declared.is_some_and(|declared| declared != principal) {
        return Err(ConversationRejected(Reject::ActorMismatch).into());
    }
    Ok(principal)
}

/// The stable reason of a conversation reject (the `reason` response field).
pub(super) fn error_reason(error: &anyhow::Error) -> Option<String> {
    error
        .downcast_ref::<ConversationRejected>()
        .map(|rejected| rejected.0.code().to_string())
        .or_else(|| {
            error.downcast_ref::<ConversationSearchRejected>().map(|r| r.0.code().to_string())
        })
        .or_else(|| error.downcast_ref::<AttachmentRejected>().map(|r| r.0.to_string()))
        .or_else(|| error.downcast_ref::<RunRejected>().map(|r| r.0.to_string()))
}

/// The `error_details` of a conversation reject that has them: the keyed
/// conversation of a create's `idempotency_conflict`.
pub(super) fn error_details(error: &anyhow::Error) -> Option<Value> {
    error
        .downcast_ref::<crate::conversation_store::KeyedConversation>()
        .map(|keyed| json!({"conversation": keyed.0}))
}

/// The `error_code` of a conversation reject.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    let rejected = error.downcast_ref::<ConversationRejected>().is_some()
        || error.downcast_ref::<ConversationSearchRejected>().is_some();
    if error.downcast_ref::<AttachmentRejected>().is_some() {
        return Some(AttachmentRejected::CODE.to_string());
    }
    if error.downcast_ref::<RunRejected>().is_some() {
        return Some(RunRejected::CODE.to_string());
    }
    rejected.then(|| ConversationRejected::CODE.to_string())
}

/// The agent-identity commands (`conversation-bind`, `conversation-agent-token`)
/// and `conversation-import` stay on the Unix socket: a WebSocket client is
/// the person, never an agent or another person, and never rewrites history.
fn require_unix(mux: &Mux, client: u64) -> anyhow::Result<()> {
    anyhow::ensure!(
        mux.control_clients.is_unix(client),
        "this conversation command requires a local Unix socket connection"
    );
    Ok(())
}

fn require_local(mux: &Mux, client: u64) -> anyhow::Result<()> {
    anyhow::ensure!(
        mux.control_clients.is_owner_client(client),
        "local conversations require a trusted local connection"
    );
    Ok(())
}

pub(super) fn decode<T: DeserializeOwned>(value: Value, field: &str) -> anyhow::Result<T> {
    serde_json::from_value(value).map_err(|error| anyhow::anyhow!("bad request: {field}: {error}"))
}

pub(super) fn validate_page(value: u32, field: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        (1..=MAX_PAGE_MESSAGES).contains(&value),
        "bad request: {field} must be 1-{MAX_PAGE_MESSAGES}"
    );
    Ok(())
}

pub(super) fn list(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    if mux.is_remote_client(client) {
        return super::remote_relay::conversations::list(mux, client);
    }
    require_local(mux, client)?;
    // The caller's own pins and marks ride on its summaries
    // (`conversation-inbox-state-v1`); nobody else's.
    let principal = mux.conversation_principal(client);
    let (conversations, states) =
        mux.with_conversations(|store| Ok((store.list()?, store.inbox_states(&principal)?)))?;
    let conversations: Vec<Value> = conversations
        .into_iter()
        .map(|summary| {
            let state = states.get(&summary.id).copied().unwrap_or_default();
            let mut value = serde_json::to_value(summary)?;
            if let (Value::Object(fields), Value::Object(state)) =
                (&mut value, serde_json::to_value(state)?)
            {
                fields.extend(state);
            }
            Ok(value)
        })
        .collect::<anyhow::Result<_>>()?;
    Ok(json!({"conversations": conversations}))
}

/// `home-inbox`: the caller's Home rows over the local conversations
/// (`cmux_conversation::home_inbox`): the same summaries as
/// `conversation-list`, with the caller's pins and marks, the Chief
/// registry's current names and who types now.
pub(super) fn home_inbox(mux: &Mux, client: u64, params: HomeInboxParams) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    let owners = params.owners.unwrap_or_else(|| vec!["local".into(), "cloud".into()]);
    anyhow::ensure!(
        owners.iter().all(|owner| owner == "local" || owner == "cloud"),
        "bad request: owners"
    );
    let (cloud_rows, cloud) = if owners.iter().any(|owner| owner == "cloud") {
        cloud_home_rows(mux, client)
    } else {
        (Vec::new(), "not_asked")
    };
    if !owners.iter().any(|owner| owner == "local") {
        let principal = mux.conversation_principal(client);
        let rows = cmux_conversation::merge_rows(Vec::new(), cloud_rows);
        return Ok(json!({"me": principal, "rows": rows, "cloud": cloud}));
    }
    let principal = mux.conversation_principal(client);
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX));
    // One read of the store: the summaries, my list state and the runs agree.
    let (conversations, states, running) = mux.with_conversations(|store| {
        Ok((store.list()?, store.inbox_states(&principal)?, store.running_run_authors(now_ms)?))
    })?;
    let input = cmux_conversation::HomeInboxInput {
        me: &principal,
        states: states
            .into_iter()
            .map(|(id, state)| {
                (
                    id,
                    cmux_conversation::HomeListState {
                        pinned: state.pinned,
                        pin_position: state.pin_position,
                        marked_unread: state.marked_unread,
                    },
                )
            })
            .collect(),
        chief_names: super::chief_registry_resource::chief_names(mux),
        typing: mux.conversation_typing_all(),
        running,
        deleted_chiefs: super::chief_registry_resource::deleted_chiefs(mux),
    };
    let rows = cmux_conversation::merge_rows(
        cmux_conversation::home_inbox(&conversations, &input),
        cloud_rows,
    );
    Ok(json!({"me": principal, "rows": rows, "cloud": cloud}))
}

/// The person's Cloud inbox as Home rows, through the daemon's lease, and
/// whether they are in: `included`, `signed_out` (this connection is not the
/// person with the app's lease, or there is no lease or no Cloud here) or
/// `unavailable` (the Cloud did not answer). A Cloud failure never hides the
/// local rows. Every page of the inbox within a time budget (`inbox_list_all`).
fn cloud_home_rows(mux: &Mux, client: u64) -> (Vec<cmux_conversation::HomeRow>, &'static str) {
    // Only the person's own clients (the app, an authenticated page) get the
    // person's rows; any other connection never reads a lease.
    if !super::cloud_conversations::is_person(mux, client) {
        return (Vec::new(), "signed_out");
    }
    // The read holds one of the Cloud's request slots, as cloud-inbox-list does.
    let listed = super::cloud_conversations::lease_user(mux, client).and_then(|service| {
        let _permit = service.begin_request()?;
        service
            .inbox_list_all(false, crate::cloud_conversations::INBOX_ALL_BUDGET)
            .map_err(anyhow::Error::from)
    });
    let value = match listed {
        Ok(value) => value,
        Err(error) => return (Vec::new(), cloud_rows_failure(&error)),
    };
    let Some(entries) = value.get("entries").and_then(Value::as_array) else {
        return (Vec::new(), "unavailable");
    };
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX));
    // One malformed entry is skipped, never the whole inbox.
    let rows = entries
        .iter()
        .filter_map(|entry| serde_json::from_value(entry.clone()).ok())
        .filter_map(|entry: cmux_conversation::CloudInboxEntry| {
            cmux_conversation::cloud_row(&entry, now_ms)
        })
        .collect();
    (rows, "included")
}

/// The Cloud rows' state after a failed inbox read: `signed_out` only when
/// there is no usable lease (none, expired, the token refused, or no Cloud
/// here); any other failure, a refusal of one page (a rate limit, an old
/// cursor) included, is `unavailable`, so the app keeps its last rows.
pub(super) fn cloud_rows_failure(error: &anyhow::Error) -> &'static str {
    use crate::cloud_conversations::CloudError;
    match error.downcast_ref::<CloudError>() {
        Some(CloudError::SignedOut | CloudError::SessionExpired | CloudError::Unauthenticated) => {
            "signed_out"
        }
        Some(_) => "unavailable",
        None => "signed_out",
    }
}

/// `conversation-inbox-op`: sets the caller's own pin or "marked unread" of
/// a conversation it takes part in, and publishes `conversation-inbox-changed`
/// to the caller's connections. Not a conversation op: no rev, no ledger
/// (values are absolute, so a retry writes the same state).
pub(super) fn inbox_op(mux: &Mux, client: u64, params: InboxOpParams) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    let InboxOpParams { conversation, op } = params;
    let op: InboxOp = decode(op, "op")?;
    let actor = mux.conversation_principal(client);
    let state = mux.conversation_write(
        |store| store.apply_inbox_op(&conversation, &actor, &op),
        |state| {
            Some(MuxEvent::Conversation(Arc::new(ConversationEvent::Inbox {
                conversation: conversation.clone(),
                participant: actor.clone(),
                pinned: state.pinned,
                pin_position: state.pin_position,
                marked_unread: state.marked_unread,
            })))
        },
    )?;
    let mut reply = json!({"conversation": conversation, "participant": actor});
    if let (Value::Object(fields), Value::Object(state)) =
        (&mut reply, serde_json::to_value(state)?)
    {
        fields.extend(state);
    }
    Ok(reply)
}

pub(super) fn create(mux: &Mux, client: u64, params: CreateParams) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    let CreateParams { idempotency_key, actor, title, participants } = params;
    let actor = resolve_actor(mux, client, actor)?;
    let participants: Vec<Participant> = decode(participants, "participants")?;
    // Device participants come only from the pairing system path.
    if participants.iter().any(|participant| is_device_id(&participant.id)) {
        return Err(device_id_refused());
    }
    let outcome = mux.conversation_write(
        |store| store.create(&idempotency_key, &actor, &title, &participants),
        |outcome| {
            if outcome.replayed {
                return None;
            }
            let change = Change::Conversation { conversation: Box::new(outcome.summary.clone()) };
            Some(MuxEvent::Conversation(Arc::new(ConversationEvent::Changed {
                conversation: outcome.summary.id.clone(),
                rev: outcome.summary.rev,
                transaction: None,
                change: serde_json::to_value(change).ok()?,
            })))
        },
    )?;
    Ok(json!({"conversation": outcome.summary, "replayed": outcome.replayed}))
}

pub(super) fn import(mux: &Mux, client: u64, params: ImportParams) -> anyhow::Result<Value> {
    anyhow::ensure!(!mux.is_remote_client(client), "conversation-import is local only");
    require_unix(mux, client)?;
    anyhow::ensure!(
        mux.conversation_principal(client) == LOCAL_USER,
        "only the local user imports conversation history"
    );
    let ImportParams { conversation, messages } = params;
    let outcome = mux.conversation_write(
        |store| store.import(&conversation, &messages),
        |outcome| {
            if outcome.imported.is_empty() {
                return None;
            }
            let change = Change::Conversation { conversation: Box::new(outcome.summary.clone()) };
            Some(MuxEvent::Conversation(Arc::new(ConversationEvent::Changed {
                conversation: outcome.summary.id.clone(),
                rev: outcome.summary.rev,
                transaction: None,
                change: serde_json::to_value(change).ok()?,
            })))
        },
    )?;
    Ok(
        json!({"conversation": outcome.summary, "imported": outcome.imported, "skipped": outcome.skipped}),
    )
}

pub(super) fn snapshot(mux: &Mux, client: u64, params: SnapshotParams) -> anyhow::Result<Value> {
    if mux.is_remote_client(client) {
        return super::remote_relay::conversations::snapshot(mux, client, params);
    }
    require_local(mux, client)?;
    let SnapshotParams { conversation, tail } = params;
    validate_page(tail, "tail")?;
    let (summary, messages, threads) = mux.with_conversations(|store| {
        let (summary, messages) = store.snapshot(&conversation, tail)?;
        let threads = store.thread_summaries(&conversation, &messages)?;
        Ok((summary, messages, threads))
    })?;
    Ok(json!({"conversation": summary, "messages": messages, "threads": threads}))
}

pub(super) fn history(mux: &Mux, client: u64, params: HistoryParams) -> anyhow::Result<Value> {
    if mux.is_remote_client(client) {
        return super::remote_relay::conversations::history(mux, client, params);
    }
    require_local(mux, client)?;
    let HistoryParams { conversation, before_seq, limit } = params;
    validate_page(limit, "limit")?;
    let (messages, threads) = mux.with_conversations(|store| {
        let messages = store.history(&conversation, before_seq, limit)?;
        let threads = store.thread_summaries(&conversation, &messages)?;
        Ok((messages, threads))
    })?;
    Ok(json!({"messages": messages, "threads": threads}))
}

pub(super) fn thread(mux: &Mux, client: u64, params: ThreadParams) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    let ThreadParams { conversation, root, after_seq, limit } = params;
    let limit = limit.unwrap_or(THREAD_PAGE);
    validate_page(limit, "limit")?;
    let page =
        mux.with_conversations(|store| store.thread(&conversation, &root, after_seq, limit))?;
    Ok(serde_json::to_value(page)?)
}

pub(super) fn link_resolve(
    mux: &Mux,
    client: u64,
    params: LinkResolveParams,
) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    let link = cmux_conversation::parse_link(&params.url).ok_or_else(|| {
        anyhow::anyhow!("bad request: url is not a cmux conversation or message link")
    })?;
    let resolved = mux.with_conversations(|store| store.resolve_link(&link))?;
    Ok(serde_json::to_value(resolved)?)
}

pub(super) fn search(mux: &Mux, client: u64, params: SearchParams) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    let SearchParams { query, limit } = params;
    // The owner stamps the actor: a search sees only the caller's conversations.
    let actor = mux.conversation_principal(client);
    let input = cmux_conversation::SearchInput { query, limit };
    let hits = mux.with_conversations(|store| store.search(&actor, &input))?;
    Ok(json!({"hits": hits}))
}

pub(super) fn op(mux: &Mux, client: u64, params: OpParams) -> anyhow::Result<Value> {
    if mux.is_remote_client(client) {
        return super::remote_relay::conversations::op(mux, client, params);
    }
    require_local(mux, client)?;
    let OpParams { conversation, idempotency_key, actor, transaction, op } = params;
    let actor = resolve_actor(mux, client, actor)?;
    validate_client_transaction(transaction.as_deref())?;
    let op: Op = decode(op, "op")?;
    if let Op::ParticipantsAdd { participant } = &op
        && is_device_id(&participant.id)
    {
        return Err(device_id_refused());
    }
    let transaction: Option<Arc<str>> = transaction.map(Arc::from);
    let outcome = commit_op(mux, &conversation, &idempotency_key, &actor, &op, &transaction)?;
    Ok(op_reply(&outcome, outcome.result.change.clone(), transaction))
}

/// Commit `op` as `actor` and publish its `conversation-changed` (not for a
/// replay). Shared by the local and the remote handler.
pub(super) fn commit_op(
    mux: &Mux,
    conversation: &str,
    idempotency_key: &str,
    actor: &str,
    op: &Op,
    transaction: &Option<Arc<str>>,
) -> anyhow::Result<OpOutcome> {
    mux.conversation_write(
        |store| store.apply_op(conversation, idempotency_key, actor, op),
        |outcome| {
            if outcome.replayed {
                return None;
            }
            Some(MuxEvent::Conversation(Arc::new(ConversationEvent::Changed {
                conversation: conversation.to_string(),
                rev: outcome.result.rev,
                transaction: transaction.clone(),
                change: outcome.result.change.clone(),
            })))
        },
    )
}

/// The `conversation-op` reply with `change` (local or projected).
pub(super) fn op_reply(outcome: &OpOutcome, change: Value, transaction: Option<Arc<str>>) -> Value {
    let result = &outcome.result;
    let mut reply = json!({"rev": result.rev, "replayed": outcome.replayed, "change": change});
    if let Some(seq) = result.seq {
        reply.insert("seq", json!(seq));
    }
    if let Some(transaction) = transaction {
        reply.insert("transaction", json!(&*transaction));
    }
    reply
}

pub(super) fn typing(mux: &Mux, client: u64, params: TypingParams) -> anyhow::Result<Value> {
    if mux.is_remote_client(client) {
        return super::remote_relay::conversations::typing(mux, client, params);
    }
    require_local(mux, client)?;
    let TypingParams { conversation, actor, on } = params;
    let actor = resolve_actor(mux, client, actor)?;
    publish_typing(mux, &conversation, &actor, on)?;
    Ok(json!({}))
}

/// The same admission and `conversation.events` item as the
/// `conversation.draft` operation (conversation_resource.rs), for the
/// connection's principal.
pub(super) fn draft(mux: &Mux, client: u64, params: DraftParams) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    let principal = mux.conversation_principal(client);
    anyhow::ensure!(params.turn.len() <= 128 && !params.turn.is_empty(), "bad request: turn");
    anyhow::ensure!(params.text.len() <= 65536, "bad request: text");
    anyhow::ensure!(matches!(params.kind.as_str(), "talk" | "thought"), "bad request: kind");
    anyhow::ensure!(
        params.harness.as_ref().is_none_or(|harness| harness.len() <= 64),
        "bad request: harness"
    );
    let mut fields = json!({
        "turn": params.turn, "segment": params.segment, "seq": params.seq,
        "kind": params.kind, "text": params.text, "fresh": params.fresh, "done": params.done,
    });
    if let Some(truncated) = params.truncated {
        fields.insert("truncated", json!(truncated));
    }
    if let Some(harness) = params.harness {
        fields.insert("harness", json!(harness));
    }
    let published =
        super::conversation_resource::publish_draft(mux, &params.conversation, &principal, &fields)
            .map_err(|refusal| match refusal {
                super::conversation_resource::DraftRefused::Owner(error) => error,
                other => anyhow::anyhow!("draft refused: {}", other.reason()),
            })?;
    Ok(json!({"published": published}))
}

/// Validate and publish a typing indicator of `actor`. Never stored.
pub(super) fn publish_typing(
    mux: &Mux,
    conversation: &str,
    actor: &str,
    on: bool,
) -> anyhow::Result<()> {
    mux.conversation_write(
        |store| store.check_typing(conversation, actor),
        |_| {
            mux.set_conversation_typing(conversation, actor, on);
            Some(MuxEvent::Conversation(Arc::new(ConversationEvent::Typing {
                conversation: conversation.to_string(),
                participant: actor.to_string(),
                on,
            })))
        },
    )
}

pub(super) fn bind(mux: &Mux, client: u64, params: BindParams) -> anyhow::Result<Value> {
    require_unix(mux, client)?;
    let BindParams { participant, token } = params;
    anyhow::ensure!(
        crate::conversation_store::credentialed(&participant),
        "only agent participants and other people bind with a token"
    );
    // The check and the binding under one lock: a credential that
    // chief.profile.adopt revoked never binds after the adopt.
    let valid = mux.bind_conversation_principal_if(client, participant.clone(), || {
        mux.with_conversations(|store| store.verify_agent_token(&participant, &token))
    })?;
    anyhow::ensure!(valid, "conversation agent token is not valid for {participant}");
    Ok(json!({"participant": participant}))
}

pub(super) fn agent_token(
    mux: &Mux,
    client: u64,
    params: AgentTokenParams,
) -> anyhow::Result<Value> {
    require_unix(mux, client)?;
    anyhow::ensure!(
        mux.conversation_principal(client) == LOCAL_USER,
        "only the local user mints agent tokens"
    );
    anyhow::ensure!(
        crate::conversation_store::credentialed(&params.participant),
        "participant tokens are only for agents and other people"
    );
    // A Chief record's credential (other than the default Chief's): with a
    // brain supervisor only its brain gets one (minted in process); without
    // one, only the person's own terminal mints it, never a page, a paired or
    // remote device or an agent (chief.profile.adopt, hq-6d 2026-10-14). The
    // check and the mint run under the registry lock, so an adopt cannot land
    // between them.
    let terminal = !mux.is_remote_client(client)
        && super::origin_gate::connection_page(mux, client).is_none()
        && !super::origin_gate::is_page(mux, client);
    let token =
        super::chief_registry_resource::mint_credential(mux, &params.participant, terminal)?;
    // A replaced token also ends the connections bound with the old one.
    mux.unbind_conversation_participant(&params.participant);
    Ok(json!({"participant": params.participant, "token": token}))
}

#[cfg(test)]
#[path = "conversation_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "conversation_attachment_tests.rs"]
mod attachment_tests;
