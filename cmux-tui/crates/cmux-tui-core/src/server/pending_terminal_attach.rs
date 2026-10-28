//! An attach to a terminal whose host still adopts after a restart, or
//! whose shell respawns (a cold start: every host is dead). A restarted
//! owner answers before it adopted its surviving hosts or ended its dead
//! ones, and does both a few at a time (`ADOPTION_REPLAYS`), in record
//! order; the respawns follow in the background (`terminal_respawn/launches.rs`).
//! The app attaches the terminals it shows: such an attach moves that
//! terminal's adoption, then its respawn, ahead of the queued ones
//! (`Permits::promote`) and waits for them, at most [`ATTACH_ADOPTION_WAIT`]
//! together, then attaches. Chrome's session restore
//! loads the shown tab first and the background tabs after it
//! (chrome/browser/sessions/tab_loader.cc); before, the attach failed with
//! "unknown surface" and the app retried until the queue reached it.
//!
//! The wait runs on a work item, as a sized browser attach's does
//! (connection_frame.rs): the connection's next request answers meanwhile,
//! and no other connection waits. The item holds no mux, state or registry
//! lock while it waits.

use super::*;
use cmux_threads::work::{Lane, Priority, Shutdown};
use std::time::Duration;

/// The longest an attach waits for its terminal's adoption and respawn. One
/// promoted adoption takes at most the host handshake bound (2 s) and its
/// replay, a respawn one host launch; past this the attach runs and fails as
/// before, and the app retries.
const ATTACH_ADOPTION_WAIT: Duration = Duration::from_secs(4);

/// The host id of the terminal `cmd` attaches to, when it is an attach of
/// this machine's client to a terminal that has no runtime yet because its
/// host still adopts or its shell respawns.
pub(super) fn adopting_target(mux: &Mux, client: u64, cmd: &Command) -> Option<String> {
    let Command::AttachSurface(params) = cmd else { return None };
    // A remote client takes the relay gate's path, unchanged.
    if mux.is_remote_client(client) {
        return None;
    }
    match (params.surface, params.expected_terminal_id.as_deref()) {
        (Some(surface), _) => {
            if mux.surface(surface).is_some_and(|surface| !surface.is_dead()) {
                return None;
            }
            mux.adopting_terminal_for_attach(Some(surface), None)
        }
        (None, Some(terminal)) => {
            let terminal = TerminalPublicId::parse(terminal).ok()?;
            if mux.resource_surface_for_terminal(&terminal).is_some() {
                return None;
            }
            mux.adopting_terminal_for_attach(None, Some(&terminal))
        }
        (None, None) => None,
    }
}

/// Answers `cmd`, an attach [`adopting_target`] named `host_id` for, from a
/// work item that first promotes and waits for that terminal's adoption.
/// Returns whether the connection stays open.
pub(super) fn start(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    cmd: Command,
    host_id: String,
    reply: AsyncReply,
    writer: &MessageWriter,
) -> bool {
    let (worker_mux, worker_writer, worker_id) = (mux.clone(), writer.clone(), id.clone());
    let reply = reply.hand_to_worker();
    let posted = mux.work.post(
        Priority::UserBlocking,
        Lane::System,
        Shutdown::ContinueOnShutdown,
        move || {
            let reply = reply.start();
            cmux_threads::work::will_block(|| {
                worker_mux.wait_for_restored_terminal(&host_id, ATTACH_ADOPTION_WAIT);
            });
            let result =
                handle_command_with_cancellation(&worker_mux, client, cmd, &worker_writer, None);
            reply.reply(|| {
                send_command_result(&worker_mux, client, worker_id, result, &worker_writer).1
            });
        },
    );
    posted.is_ok() || send_request_error(writer, id, "the daemon is shutting down")
}
