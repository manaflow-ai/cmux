//! Raw protocol handlers for the cloud conversations proxy
//! (`cloud-conversations-v1`, plans/cmux-next/home-cloud-proxy.md). The
//! Durable Objects own the data; these handlers forward to the daemon's cloud
//! link on trusted local connections only. Commands that call the cloud run
//! on a worker thread, so a slow cloud never delays the connection's other
//! requests; their replies are matched by `id`.

use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Value, json};

use super::{Command, MessageWriter, Mux, Response, handle_command_with_cancellation, responses};
use crate::cloud_conversations::{CloudConversations, CloudError, OpRequest, Target};

pub(super) use crate::cloud_conversations::{
    CLOUD_CONVERSATIONS_CAPABILITY as CAPABILITY, SessionParams,
};

/// `cloud-inbox-list`.
#[derive(Deserialize)]
pub(super) struct InboxListParams {
    #[serde(default)]
    limit: Option<u32>,
    #[serde(default)]
    include_archived: bool,
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

/// `cloud-conversation-subscribe` / `cloud-conversation-unsubscribe`.
#[derive(Deserialize)]
pub(super) struct TargetParams {
    conversation: String,
}

/// The stable `reason` of a cloud error (the reply's `reason` field).
pub(super) fn error_reason(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<CloudError>().and_then(CloudError::reason)
}

/// The `error_code` of a cloud error.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<CloudError>().and_then(CloudError::error_code).map(str::to_string)
}

/// The reply's `retryable` flag of a cloud error.
pub(super) fn error_retryable(error: &anyhow::Error) -> Option<bool> {
    error.downcast_ref::<CloudError>().and_then(CloudError::retryable)
}

fn service(mux: &Mux, client: u64) -> anyhow::Result<&CloudConversations> {
    anyhow::ensure!(
        mux.control_clients.is_unix(client),
        "cloud conversations require a trusted local connection"
    );
    mux.cloud_conversations()
        .ok_or_else(|| anyhow::anyhow!("cloud conversations are not available in this daemon"))
}

pub(super) fn session_set(mux: &Mux, client: u64, params: SessionParams) -> anyhow::Result<Value> {
    Ok(service(mux, client)?.set_session(params)?)
}

pub(super) fn session_clear(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    Ok(service(mux, client)?.clear_session())
}

pub(super) fn session_status(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    Ok(service(mux, client)?.session_status())
}

pub(super) fn inbox_list(mux: &Mux, client: u64, params: InboxListParams) -> anyhow::Result<Value> {
    Ok(service(mux, client)?.inbox_list(params.limit, params.include_archived)?)
}

pub(super) fn snapshot(mux: &Mux, client: u64, params: SnapshotParams) -> anyhow::Result<Value> {
    Ok(service(mux, client)?.snapshot(&params.conversation, params.tail)?)
}

pub(super) fn history(mux: &Mux, client: u64, params: HistoryParams) -> anyhow::Result<Value> {
    let HistoryParams { conversation, before_seq, limit } = params;
    Ok(service(mux, client)?.history(&conversation, before_seq, limit)?)
}

pub(super) fn op(mux: &Mux, client: u64, request: OpRequest) -> anyhow::Result<Value> {
    Ok(service(mux, client)?.op(&request)?)
}

pub(super) fn subscribe(mux: &Mux, client: u64, target: Option<TargetParams>) -> anyhow::Result<Value> {
    let target = target.map_or(Target::Inbox, |params| Target::Conversation(params.conversation));
    Ok(service(mux, client)?.subscribe(client, target)?)
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

/// Whether `cmd` calls the cloud and should leave the request loop.
pub(super) fn is_network(cmd: &Command) -> bool {
    matches!(
        cmd,
        Command::CloudInboxList(_)
            | Command::CloudConversationSnapshot(_)
            | Command::CloudConversationHistory(_)
            | Command::CloudConversationOp(_)
    )
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
    let precheck = service(mux, client).and_then(|service| match &cmd {
        Command::CloudConversationOp(request) => Ok(service.check_op(request)?),
        _ => Ok(()),
    });
    if let Err(error) = precheck {
        return send(writer, id, Err(error));
    }
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new().name("mux-cloud-request".into()).spawn(move || {
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
            Response { id, ok: true, data: Some(data), error: None, error_code: None, error_delivery: None },
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
        ),
    }
}

#[cfg(test)]
#[path = "cloud_conversation_tests.rs"]
mod tests;
