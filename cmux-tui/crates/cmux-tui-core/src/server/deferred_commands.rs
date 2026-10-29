//! Raw commands whose work waits on another thread: `delete-terminal-commands`
//! (the command history worker) and `set-cell-pixels` (the terminal hosts).
//! The request thread checks the request, hands the work to the mux and
//! returns; the answer is sent from where the work finishes, through an
//! [`AsyncReply`]. Chrome replies the same way from a posted
//! task (base/task/thread_pool.h `PostTaskAndReplyWithResult`).
//!
//! A remote client never takes this path: `remote_relay::intercept` refuses
//! both commands on the synchronous one.

use std::sync::{Arc, Weak};

use serde_json::{Value, json};

use super::{
    AsyncReply, Command, DeliveryClassifiedError, MessageWriter, Mux, RequestSpan, Response,
    cmd_sizing, command_history, responses, terminal_io_wire::SetCellPixelsParams,
};

/// Whether `cmd` takes this path.
pub(super) fn handles(mux: &Mux, client: u64, cmd: &Command) -> bool {
    matches!(cmd, Command::DeleteTerminalCommands(_) | Command::SetCellPixels(_))
        && !mux.is_remote_client(client)
}

/// Starts a command [`handles`] accepted and returns whether the
/// connection stays open.
pub(super) fn start(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    cmd: Command,
    span: &mut RequestSpan<'_>,
    writer: &MessageWriter,
) -> bool {
    match cmd {
        Command::DeleteTerminalCommands(params) => {
            let deletion = match command_history::deletion(mux, client, params) {
                Ok(deletion) => deletion,
                Err(error) => return span.reply(|| send(writer, id, Err(error))),
            };
            let answer = Deferred::start(mux, id, span, writer);
            mux.delete_terminal_commands_then(deletion, move |deleted| {
                answer.send(deleted.map(|deleted| json!({ "deleted": deleted })));
            });
            true
        }
        Command::SetCellPixels(SetCellPixelsParams { width_px, height_px }) => {
            let answer = Deferred::start(mux, id, span, writer);
            mux.set_cell_pixel_size_then(width_px, height_px, move |update| {
                answer.send(update.map(cmd_sizing::cell_pixels_answer));
            });
            true
        }
        _ => span.reply(|| send(writer, id, Err(anyhow::anyhow!("not a deferred command")))),
    }
}

/// The reply of one deferred request.
struct Deferred {
    mux: Weak<Mux>,
    id: Option<Value>,
    reply: AsyncReply,
    writer: MessageWriter,
}

impl Deferred {
    fn start(
        mux: &Arc<Mux>,
        id: Option<Value>,
        span: &mut RequestSpan<'_>,
        writer: &MessageWriter,
    ) -> Self {
        Self { mux: Arc::downgrade(mux), id, reply: span.start_async(), writer: writer.clone() }
    }

    /// Sends the answer, then flushes the registry commits the work made, as
    /// the synchronous path does after its reply.
    fn send(self, result: anyhow::Result<Value>) {
        let Self { mux, id, reply, writer } = self;
        reply.reply(|| send(&writer, id, result));
        if let Some(mux) = mux.upgrade() {
            mux.request_registry_flush();
        }
    }
}

/// The response the synchronous dispatcher would send for `result`.
fn send(writer: &MessageWriter, id: Option<Value>, result: anyhow::Result<Value>) -> bool {
    let response = match result {
        Ok(data) => Response {
            id,
            ok: true,
            data: Some(data),
            error: None,
            error_code: None,
            error_delivery: None,
        },
        Err(error) => Response {
            id,
            ok: false,
            data: None,
            error_code: responses::response_error_code(&error),
            error_delivery: error
                .downcast_ref::<DeliveryClassifiedError>()
                .map(|error| error.delivery),
            error: Some(error.to_string()),
        },
    };
    responses::send_response(writer, response)
}
