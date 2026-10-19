//! `tailnet.state`: the node's state as a stream. The first item is the
//! current state; then one item per change the IPN bus reports (a wake from
//! the owner, coalesced, never a timer). The stream ends when the connection
//! closes or cancels it.

use std::sync::Arc;
use std::sync::atomic::Ordering;

use serde_json::json;

use super::super::resource_attach::{
    cleanup_resource_stream, register_resource_outbound, resource_stream_id,
    send_resource_uncursored_stream_item,
};
use super::super::{
    MessageWriter, Mux, ResourceOperation, resource_stream_end, send_resource_response,
};
use super::owner::owner;
use crate::resource_router::ParsedResourceRequest;
use crate::stream_interrupt::{StreamInterrupt, signal};

const OPERATION: ResourceOperation = ResourceOperation::TailnetState;

pub(super) fn open(
    mux: &Arc<Mux>,
    client: u64,
    request: ParsedResourceRequest,
    writer: &MessageWriter,
) -> bool {
    let id = request.envelope.id.clone();
    let stream_id = match resource_stream_id(&request) {
        Ok(stream_id) => stream_id,
        Err(error) => return send_resource_response(writer, id, OPERATION, Err(error)),
    };
    let overflow =
        resource_stream_end(&stream_id, "gap", None, Some("open tailnet.state again"), None);
    let outbound = match writer.start_stream(&overflow) {
        Ok(outbound) => outbound,
        Err(error) => {
            let error = crate::resource::ResourceError::transport_closed(error.to_string());
            return send_resource_response(writer, id, OPERATION, Err(error));
        }
    };
    let (canceled, permit) =
        match register_resource_outbound(mux, client, &stream_id, &outbound, OPERATION.wire_name())
        {
            Ok(installed) => installed,
            Err(error) => return send_resource_response(writer, id, OPERATION, Err(error)),
        };
    if !send_resource_response(writer, id, OPERATION, Ok(json!({"stream_id": stream_id}))) {
        cleanup_resource_stream(mux, client, &stream_id);
        return false;
    }
    let owner = owner();
    // Subscribe before the first read, so no change falls between them.
    let (wake, changes) = signal();
    owner.watch(wake);
    let (worker_mux, worker_writer, worker_stream) =
        (mux.clone(), writer.clone(), stream_id.clone());
    let spawned = std::thread::Builder::new().name("mux-tailnet-state".into()).spawn(move || {
        let _permit = permit;
        owner.resume(&worker_mux);
        let interrupt = StreamInterrupt::new();
        worker_writer.register_interrupt(&interrupt);
        outbound.register_interrupt(&interrupt);
        changes.wake_on(&interrupt);
        let mut sequence = 0_u64;
        let mut sent = None;
        loop {
            if !worker_writer.is_open() || !outbound.is_open() || canceled.load(Ordering::Acquire) {
                break;
            }
            let (snapshot, version) = owner.current();
            if sent != Some(version) {
                if !send_resource_uncursored_stream_item(
                    &worker_writer,
                    &outbound,
                    &worker_stream,
                    sequence,
                    snapshot.to_json(),
                ) {
                    break;
                }
                sent = Some(version);
                sequence = sequence.saturating_add(1);
            }
            // An error: the connection or the stream closed (the interrupt).
            if changes.recv_until_interrupted(&interrupt).is_err() {
                break;
            }
        }
        worker_mux.control_clients.finish_resource_stream(client, &worker_stream, outbound.id);
    });
    if spawned.is_err() {
        cleanup_resource_stream(mux, client, &stream_id);
    }
    true
}
