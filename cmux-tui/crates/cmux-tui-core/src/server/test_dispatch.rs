//! Native connection test adapters; production uses the admitted connection path.
use super::*;

pub(super) fn handle_connection(mux: Arc<Mux>, stream: Box<dyn transport::Stream>) {
    handle_connection_with_permit(mux, stream, Arc::new(RenderService::new()), None);
}

pub(super) fn handle_message(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> bool {
    match serde_json::from_str::<Request>(message) {
        Ok(request) => handle_request(mux, client, request, writer),
        Err(error) => send_bad_request(writer, message, &error),
    }
}
