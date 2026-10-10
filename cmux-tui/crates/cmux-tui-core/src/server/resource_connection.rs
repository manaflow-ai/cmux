//! Resource-protocol connection routing: dispatching a parsed resource
//! request to its handler (clients, sessions, waits, attach streams,
//! journals, renderer grants), session shutdown, connection control
//! operations, and stream item delivery, cancellation and end.

use super::cleanup_resource_attach;
use super::cleanup_resource_stream;
use super::handle_journal_extension_request;
use super::prepare_browser_resource_attach;
use super::prepare_resource_client_detach;
use super::prepare_session_event_stream;
use super::prepare_session_journal_stream;
use super::prepare_sidebar_resource_attach;
use super::prepare_terminal_resource_attach;
use super::resource_browser_viewer_release;
use super::resource_browser_viewer_resize;
use super::resource_client_cell_pixels_set;
use super::resource_client_get;
use super::resource_client_list;
use super::resource_client_metadata_update;
use super::resource_client_sizing_release;
use super::resource_client_sizing_set;
use super::resource_session_snapshot;
use super::resource_terminal_viewer_release;
use super::resource_terminal_viewer_resize;
use super::send_resource_response;
use super::start_browser_resource_attach;
use super::start_resource_wait;
use super::start_session_event_stream;
use super::start_session_journal_stream;
use super::start_sidebar_resource_attach;
use super::start_terminal_resource_attach;

use super::MessageWriter;
use super::OutboundStream;
use super::ResourceWaitCancel;
use super::activity;
use super::chief_control;
use super::complete_daemon_shutdown_after_ack;
use super::conversation_resource;
use super::detach_actor;
use super::handles_resource_connection_operation;
use super::kick_client;
use super::origin_gate;
use super::renderer_grant;
use super::trusted_local_resource_client;
use crate::Mux;
use crate::mux::DaemonHandoffRequest;
use crate::resource::RequestId as ResourceRequestId;
use crate::resource::ResourceError;
use crate::resource::ResourceOperation;
use crate::resource::StreamPublicId;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;
use std::sync::atomic::Ordering;

fn handle_resource_session_shutdown(
    mux: &Arc<Mux>,
    client: u64,
    request: crate::resource_router::ParsedResourceRequest,
    id: ResourceRequestId,
    writer: &MessageWriter,
) -> bool {
    let operation = ResourceOperation::SessionShutdown;
    let force =
        request.fields["force"].as_bool().expect("catalog validates the shutdown force flag");
    let result = trusted_local_resource_client(mux, client, operation).and_then(|()| {
        mux.begin_daemon_handoff(client, DaemonHandoffRequest::unfenced(force)).map_err(|error| {
            ResourceError::operation_failed(
                "session.shutdown",
                error.to_string(),
                json!({"force":force}),
            )
        })
    });
    if let Err(error) = result {
        return send_resource_response(writer, id, operation, Err(error));
    }

    match crate::resource_router::commit_session_shutdown(mux, request) {
        Ok(result) => {
            let sent = send_resource_response(writer, id, operation, Ok(result));
            if sent {
                complete_daemon_shutdown_after_ack(mux, client, writer)
            } else {
                mux.cancel_daemon_handoff(client);
                false
            }
        }
        Err(error) => {
            mux.cancel_daemon_handoff(client);
            send_resource_response(writer, id, operation, Err(error))
        }
    }
}

/// Dispatches one request the origin gate admitted; `request` is the
/// gate's own parse of the line.
pub(super) fn handle_resource_connection_message(
    mux: &Arc<Mux>,
    client: u64,
    request: crate::resource_router::ParsedResourceRequest,
    writer: &MessageWriter,
) -> bool {
    let id = request.envelope.id.clone();
    let operation = request.envelope.operation;
    if matches!(
        operation,
        ResourceOperation::SessionShutdown | ResourceOperation::SessionReloadConfig
    ) && !mux.server_lifecycle_ready()
    {
        let operation_name = match operation {
            ResourceOperation::SessionShutdown => "session.shutdown",
            ResourceOperation::SessionReloadConfig => "session.reload_config",
            _ => unreachable!("lifecycle readiness applies only to lifecycle operations"),
        };
        return send_resource_response(
            writer,
            id,
            operation,
            Err(ResourceError::new(
                "operation.failed",
                "server lifecycle is not ready",
                json!({
                    "operation": operation_name,
                    "reason": "lifecycle_not_ready",
                }),
                false,
            )),
        );
    }
    debug_assert_eq!(
        handles_resource_connection_operation(operation),
        crate::resource_router::requires_connection_context(operation)
    );
    match operation {
        operation if conversation_resource::handles(operation) => {
            conversation_resource::handle(mux, client, request, writer)
        }
        operation if chief_control::handles(operation) => {
            chief_control::handle(mux, client, request, writer)
        }
        ResourceOperation::SessionShutdown => {
            handle_resource_session_shutdown(mux, client, request, id, writer)
        }
        ResourceOperation::PairingRequestList | ResourceOperation::PairingRequestResolve => {
            let result = trusted_local_resource_client(mux, client, operation).and_then(|()| {
                crate::resource_router::handle_trusted_local_auxiliary(mux, request)
            });
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::ClientList
        | ResourceOperation::ClientGet
        | ResourceOperation::ClientMetadataUpdate
        | ResourceOperation::ClientSizingSet
        | ResourceOperation::ClientSizingRelease
        | ResourceOperation::ClientCellPixelsSet
        | ResourceOperation::TerminalRendererGrantCreate
        | ResourceOperation::TerminalViewerResize
        | ResourceOperation::TerminalViewerRelease
        | ResourceOperation::BrowserViewerResize
        | ResourceOperation::BrowserViewerRelease => {
            let result = handle_resource_connection_control(mux, client, &request);
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::ClientDetach => {
            let result = prepare_resource_client_detach(mux, client, &request);
            match result {
                Ok(target) if target == client => {
                    if !send_resource_response(writer, id, operation, Ok(json!({}))) {
                        return false;
                    }
                    false
                }
                Ok(target) => {
                    let result = if kick_client(mux, target, detach_actor(mux, client, None)) {
                        Ok(json!({}))
                    } else {
                        Err(ResourceError::not_found(
                            "client",
                            request.selectors.client.as_deref().unwrap_or("<missing>"),
                        ))
                    };
                    send_resource_response(writer, id, operation, result)
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::TerminalAttach => {
            match prepare_terminal_resource_attach(mux, client, writer, &request) {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        cleanup_resource_attach(mux, client, &start.common);
                        return false;
                    }
                    start_terminal_resource_attach(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::BrowserAttach => {
            match prepare_browser_resource_attach(mux, client, writer, &request) {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        cleanup_resource_attach(mux, client, &start.common);
                        return false;
                    }
                    start_browser_resource_attach(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::SidebarViewAttach => {
            match prepare_sidebar_resource_attach(mux, client, writer, &request) {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        cleanup_resource_stream(mux, client, &start.stream_id);
                        return false;
                    }
                    start_sidebar_resource_attach(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::SessionEvents => {
            match prepare_session_event_stream(mux, client, writer, &request) {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        let _ = mux.control_clients.take_resource_stream(client, &start.stream_id);
                        return false;
                    }
                    start_session_event_stream(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::SessionJournalProducerList
        | ResourceOperation::SessionJournalProducerPut
        | ResourceOperation::SessionJournalAppend
        | ResourceOperation::SessionJournalHookList
        | ResourceOperation::SessionJournalHookPut
        | ResourceOperation::SessionJournalCheckpointCreate
        | ResourceOperation::SessionJournalCheckpointList
        | ResourceOperation::SessionJournalRestorePreview
        | ResourceOperation::SessionJournalSegmentList
        | ResourceOperation::SessionJournalSegmentSeal => {
            let result = trusted_local_resource_client(mux, client, operation)
                .and_then(|()| handle_journal_extension_request(mux, &request));
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::SessionJournalSubscribe => {
            let prepared = prepare_session_journal_stream(mux, client, writer, &request);
            match prepared {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        let _ = mux.control_clients.take_resource_stream(client, &start.stream_id);
                        return false;
                    }
                    start_session_journal_stream(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::SessionSnapshot => {
            let result = resource_session_snapshot(mux, client, &request.selectors);
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::TerminalWait | ResourceOperation::TerminalWaitExit => {
            start_resource_wait(mux.clone(), client, writer.clone(), request, id)
        }
        ResourceOperation::RequestCancel => {
            let result = cancel_resource_request(mux, client, writer, &request);
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::StreamCancel => {
            let result = cancel_resource_stream(mux, client, writer, &request);
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::OriginConfirmationIssue => {
            origin_gate::handle_issue(mux, client, &request, id, writer)
        }
        _ => {
            debug_assert!(
                !crate::resource_router::requires_connection_context(request.envelope.operation),
                "connection-owned operation fell through to the transport-independent router"
            );
            let operation = request.envelope.operation;
            match crate::resource_router::handle_parsed_resource_request(mux, request) {
                Ok(response) => {
                    activity::note_resource_input(mux, client, operation, &response);
                    writer.send_control(&response).is_ok()
                }
                // Only a response that cannot be encoded fails here.
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
    }
}

fn handle_resource_connection_control(
    mux: &Arc<Mux>,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    match request.envelope.operation {
        ResourceOperation::ClientList => resource_client_list(mux, client, request),
        ResourceOperation::ClientGet => resource_client_get(mux, client, request),
        ResourceOperation::ClientMetadataUpdate => {
            resource_client_metadata_update(mux, client, request)
        }
        ResourceOperation::ClientSizingSet => resource_client_sizing_set(mux, client, request),
        ResourceOperation::ClientSizingRelease => {
            resource_client_sizing_release(mux, client, request)
        }
        ResourceOperation::ClientCellPixelsSet => {
            resource_client_cell_pixels_set(mux, client, request)
        }
        ResourceOperation::TerminalViewerResize => {
            resource_terminal_viewer_resize(mux, client, request)
        }
        ResourceOperation::TerminalViewerRelease => {
            resource_terminal_viewer_release(mux, client, request)
        }
        ResourceOperation::BrowserViewerResize => {
            resource_browser_viewer_resize(mux, client, request)
        }
        ResourceOperation::BrowserViewerRelease => {
            resource_browser_viewer_release(mux, client, request)
        }
        ResourceOperation::TerminalRendererGrantCreate => {
            renderer_grant::create(mux, client, request)
        }
        operation => unreachable!("connection handler received {operation:?}"),
    }
}

pub(super) fn send_resource_stream_item(
    writer: &MessageWriter,
    outbound: &OutboundStream,
    stream_id: &StreamPublicId,
    sequence: u64,
    cursor: &Value,
    item: Value,
) -> bool {
    writer
        .send_stream_backpressured(
            &json!({
                "protocol":"cmux.protocol/2",
                "type":"stream_item",
                "stream_id":stream_id,
                "sequence":sequence.to_string(),
                "cursor":cursor,
                "item":writer.project_conversation_tab_item(item),
            }),
            outbound,
        )
        .is_ok()
}

fn cancel_resource_stream(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let route = crate::ResourceSelectors {
        machine: request.selectors.machine.clone(),
        session: request.selectors.session.clone(),
        ..Default::default()
    };
    mux.resolve_resource_path(crate::ResourceTarget::Session, &route)?;
    let stream_id: StreamPublicId = request
        .selectors
        .stream
        .as_deref()
        .ok_or_else(|| ResourceError::not_found("stream", "<missing>"))
        .and_then(|stream| StreamPublicId::parse(stream.to_string()))?;
    if let Some(stream) = mux.control_clients.take_resource_stream(client, &stream_id) {
        stream.canceled.store(true, Ordering::Release);
        let end = resource_stream_end(&stream_id, "canceled", None, None, None);
        writer
            .send_terminal(&end, &stream.outbound)
            .map_err(|_| ResourceError::transport_closed("could not end the canceled stream"))?;
    }
    Ok(json!({}))
}

fn cancel_resource_request(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let request_id = ResourceRequestId::parse(
        request.fields["request_id"].as_str().expect("catalog validates request cancellation ids"),
    )?;
    let canceled = match mux.control_clients.cancel_resource_wait(client, &request_id) {
        ResourceWaitCancel::Missing => false,
        ResourceWaitCancel::Canceled(lifecycle) => {
            lifecycle.wait_for_worker_finish();
            true
        }
        ResourceWaitCancel::Completing(lifecycle) => {
            if !lifecycle.wait_for_response_attempt() {
                writer.close();
                return Err(ResourceError::transport_closed(
                    "terminal wait completion ended before attempting its response",
                ));
            }
            false
        }
    };
    Ok(json!({"canceled":canceled}))
}

pub(super) fn resource_stream_end(
    stream_id: &StreamPublicId,
    reason: &str,
    cursor: Option<Value>,
    recovery: Option<&str>,
    error: Option<(ResourceOperation, ResourceError)>,
) -> Value {
    let mut end = json!({
        "protocol":"cmux.protocol/2",
        "type":"stream_end",
        "stream_id":stream_id,
        "reason":reason,
    });
    if let Some(cursor) = cursor {
        end["cursor"] = cursor;
    }
    if let Some(recovery) = recovery {
        end["recovery"] = json!(recovery);
    }
    if let Some((operation, error)) = error {
        let error = crate::resource_router::validate_operation_error(operation, error);
        end["error"] = json!(error);
    }
    end
}
