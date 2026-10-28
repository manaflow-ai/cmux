//! Native connection test adapters; production uses the admitted connection path.
use super::*;

/// Serves `stream` and returns once the connection ended, as the reader
/// thread a connection had did.
pub(super) fn handle_connection(mux: Arc<Mux>, stream: Box<dyn transport::Stream>) {
    let _ = serve_connection(
        mux,
        stream,
        Arc::new(RenderService::new()),
        None,
        ClientTransport::Unix,
        Box::new(admission::LocalAdmission),
        Box::<frame_dispatch::RequestFrames>::default(),
    );
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
