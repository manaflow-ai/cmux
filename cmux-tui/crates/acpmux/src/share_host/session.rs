//! One share, in its own process (`acpmux share-host session`, started by the daemon in its own
//! session): it reads `{"push": <host ticket push>, "viewOnly": bool}` from stdin, signs in with
//! this Mac's device and the machine credential (signaling and `fpSig` need the device key,
//! `/end` the account session), finds the Screen Sharing helper, and serves the ticket with it
//! (`cmux_hub_host::session::serve`, the helper's `serve` with responsibility disclaimed). Its
//! record (`sessions/<id>.json`) lives as long as it serves. SIGTERM stops it; when the share
//! ends it tells the hub (`/end`) when this side ended it, and exits. A helper that crashes ends
//! this share only.

use super::records::{self, Record};
use super::{LOG, helper};
use cmux_hub_host::hub::Hub;
use cmux_hub_host::session::{self, Ended, ServeCommand, Ticket};
use serde_json::Value;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// The longest stdin the daemon writes (one push).
const MAX_INPUT: u64 = 1 << 20;

/// `acpmux share-host session`.
pub(crate) fn run() -> anyhow::Result<()> {
    use std::io::Read;
    let mut input = String::new();
    std::io::stdin().take(MAX_INPUT).read_to_string(&mut input)?;
    let envelope: Value = serde_json::from_str(input.trim())?;
    let push = envelope.get("push").cloned().unwrap_or(Value::Null);
    let view_only = envelope.get("viewOnly").and_then(Value::as_bool) != Some(false);
    let ticket = Ticket::from_push(&push).map_err(|e| anyhow::anyhow!("{e}"))?;
    let stop = Arc::new(AtomicBool::new(false));
    let flag = stop.clone();
    // SAFETY: the handler only stores to an atomic, which is async-signal-safe.
    unsafe {
        signal_hook_registry::register(libc::SIGTERM, move || flag.store(true, Ordering::SeqCst))
    }?;
    let home = crate::config::home();
    let hub = super::machine_hub(&home, false)?;
    // Recorded before the helper is found (a first staging takes a while), so a revocation
    // meanwhile stops this process too.
    if let Some(record) = Record::of_self(&ticket) {
        let _ = records::write(&records::dir(&home), &record);
    }
    let command = match helper::resolve(&home) {
        Ok(resolved) => serve_command(resolved.executable),
        Err(why) => {
            eprintln!("{LOG}: session {}: no helper: {why}", ticket.session_id);
            if let Err(e) = hub.end(&ticket.session_id, "failed") {
                eprintln!("{LOG}: end not sent: {e}");
            }
            records::remove_if(&records::dir(&home), &ticket.session_id, std::process::id());
            anyhow::bail!("no Screen Sharing helper: {why}");
        }
    };
    let ended = serve_one(&hub, &ticket, view_only, &command, &stop, &records::dir(&home));
    eprintln!("{LOG}: session {} ended: {}", ticket.session_id, ended.reason);
    Ok(())
}

/// The helper's `serve`, its own responsible process (macOS checks its grants, never this
/// daemon's).
pub(crate) fn serve_command(program: std::path::PathBuf) -> ServeCommand {
    ServeCommand {
        program,
        args: vec!["serve".into()],
        disclaim: true,
        log_prefix: LOG.into(),
        status_prefix: LOG.into(),
    }
}

/// Serves `ticket` with `command` while this process's record in `dir` says so, then tells
/// the hub how it ended (when this side ended it) and removes the record.
pub(crate) fn serve_one(
    hub: &Hub,
    ticket: &Ticket,
    view_only: bool,
    command: &ServeCommand,
    stop: &Arc<AtomicBool>,
    dir: &Path,
) -> Ended {
    if let Some(record) = Record::of_self(ticket)
        && let Err(e) = records::write(dir, &record)
    {
        eprintln!("{LOG}: session record not written: {e}");
    }
    eprintln!(
        "{LOG}: serving a {} session for {}",
        if view_only { "view" } else { "control" },
        cmux_hub_host::printable(&ticket.peer_name)
    );
    let ended = session::serve(hub, ticket, view_only, command, stop);
    if let Some(reason) = ended.tell_hub
        && let Err(e) = hub.end(&ticket.session_id, reason)
    {
        eprintln!("{LOG}: end not sent: {e}");
    }
    records::remove_if(dir, &ticket.session_id, std::process::id());
    ended
}
