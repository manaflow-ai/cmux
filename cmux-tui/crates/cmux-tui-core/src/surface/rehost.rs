//! PTY custody and in-place host replacement for a hosted terminal
//! (cx-6so.49 L1.2).
//!
//! Whenever a hosted terminal connects to a host that supports it, the owner
//! takes custody of the host's PTY master on a short-lived thread and keeps
//! it in the connected [`HostAttachment`], so it is released exactly when
//! that runtime is: the terminal ends, its host is replaced, or the Surface
//! drops. The copy holds no slave, so a shell that exits still ends the
//! terminal normally.
//!
//! When the reconnect loop proves the host dead and the host left no exit
//! record, the owner starts a replacement host on the held master
//! (`launch_terminal_host_adopting`): same terminal id, incarnation and
//! owner token, seeded with the owner's replica of the screen and its
//! OSC 7501 program status records. The terminal
//! keeps its tab, surface and shell; the reconnect loop installs the new
//! host like any reconnect. Without custody, a live shell or a replaceable
//! state, the dead host is handled as before (a host loss).
//!
//! Windows v1 hosts have no PTY custody (cx-ko2e): a dead host is always a
//! host loss there.

use std::path::Path;
use std::sync::PoisonError;

use super::*;
#[cfg(unix)]
use crate::terminal_host_runtime::TerminalHostAdoption;
use crate::terminal_host_runtime::{HostAttachment, TerminalHostIdentity, TerminalHostRecord};

/// What the reconnect loop does after its host was proven dead.
pub(super) enum DeadHost {
    /// The terminal's end was recorded (or the owner is going away): stop.
    Stop,
    /// A live replacement host is published but could not be attached yet.
    Retry,
    /// Install this attachment to a replacement host of the same incarnation.
    Replaced(Box<HostAttachment>),
}

#[cfg(unix)]
/// The seed budget: the replay plus a pending sequence and the progress
/// suffix must fit the `LaunchAdopt` blob.
const SEED_HEADROOM_BYTES: usize = 64 * 1024;

/// Take custody of the PTY master of the host `surface` is connected to,
/// unless it holds it already or the host predates custody. Runs off the
/// reader's path; a refusal (the child already ended) leaves no custody.
#[cfg(windows)]
pub(super) fn request_custody(_surface: &Arc<Surface>) {}

#[cfg(unix)]
pub(super) fn request_custody(surface: &Arc<Surface>) {
    // Runs on the surface's reader thread, which must never wait for
    // `pty.runtime`: a control request could hold that lock briefly while it
    // sends, and only this reader delivers the reply.
    // Every lock and the custody exchange happen on a short-lived thread.
    let surface = Arc::downgrade(surface);
    // The name is unique and within Linux's 15-byte thread name, so a
    // boundary test sees in `/proc` when the custody exchange has finished.
    let _ = std::thread::Builder::new().name("pty-custody".into()).spawn(move || {
        let discovery = {
            let Some(surface) = surface.upgrade() else { return };
            let Some(pty) = surface.as_pty() else { return };
            match &*pty.runtime.lock().unwrap_or_else(PoisonError::into_inner) {
                PtyRuntime::Hosted(host)
                    if host.record.supports_pty_custody && !host.holds_pty_custody() =>
                {
                    Some(host.discovery_record())
                }
                PtyRuntime::Hosted(_) | PtyRuntime::ExitedHosted | PtyRuntime::Local { .. } => None,
            }
        };
        let Some((record, record_path)) = discovery else {
            eprintln!(
                "cmux-tui: host-replacement-probe: custody: no exchange (not hosted, no support, or held)"
            );
            return;
        };
        probe_line(
            &record.terminal_id,
            &record.incarnation,
            &format!("custody: the exchange starts with host pid {}", record.host_pid),
        );
        let custody = match crate::terminal_host_runtime::request_terminal_host_pty_custody(
            &record,
            &record_path,
        ) {
            Ok(custody) => custody,
            Err(error) => {
                probe_line(
                    &record.terminal_id,
                    &record.incarnation,
                    &format!("custody: the exchange failed: {error:#}"),
                );
                return;
            }
        };
        let Some(surface) = surface.upgrade() else { return };
        let Some(pty) = surface.as_pty() else { return };
        let mut runtime = pty.runtime.lock().unwrap_or_else(PoisonError::into_inner);
        if let PtyRuntime::Hosted(host) = &mut *runtime
            && host.record.host_start_nonce == record.host_start_nonce
            && !host.holds_pty_custody()
        {
            host.keep_pty_custody(custody);
            probe_line(
                &record.terminal_id,
                &record.incarnation,
                &format!("custody: kept for host pid {}", record.host_pid),
            );
        } else {
            probe_line(
                &record.terminal_id,
                &record.incarnation,
                "custody: dropped (the runtime changed, or custody is held)",
            );
        }
    });
}

/// PROBE, a proof branch only (never for a merge): one line on the owner's
/// stderr for each step of the path of a dead host, with a wall time in ms.
pub(super) fn probe(identity: &TerminalHostIdentity, what: &str) {
    probe_line(&identity.terminal_id, &identity.incarnation, what);
}

/// PROBE: the line of [`probe`] for a terminal id and an incarnation.
pub(super) fn probe_line(terminal_id: &str, incarnation: &str, what: &str) {
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|since| since.as_millis())
        .unwrap_or_default();
    eprintln!(
        "cmux-tui: host-replacement-probe: t={ms} terminal {terminal_id} incarnation {incarnation}: {what}"
    );
}

/// Handle the proven death of the host `record` names: attach to a live
/// replacement, start one on the held PTY master, or record the end.
pub(super) fn after_host_death(
    surface: &Arc<Surface>,
    mux: &Weak<Mux>,
    identity: &TerminalHostIdentity,
    record: &TerminalHostRecord,
    record_path: &Path,
    scrollback: usize,
) -> DeadHost {
    let Some(pty) = surface.as_pty() else { return DeadHost::Stop };
    #[cfg(windows)]
    let _ = scrollback;
    probe(identity, &format!("after the death of host pid {}", record.host_pid));
    // An earlier replacement whose install failed still serves the shell.
    if let Some(successor) =
        crate::terminal_host_runtime::live_successor_record(record_path, record)
    {
        probe(identity, &format!("a live successor record: host pid {}", successor.host_pid));
        let Some(limits) =
            mux.upgrade().and_then(|mux| mux.kitty_image_limits_for_reconnect(surface).ok())
        else {
            probe(identity, "stop: no image limits for the successor");
            return DeadHost::Stop;
        };
        return match crate::terminal_host_runtime::adopt_terminal_host_with_kitty_limits(
            successor,
            record_path.to_path_buf(),
            limits,
        ) {
            Ok(attachment) => DeadHost::Replaced(Box::new(attachment)),
            Err(error) => {
                probe(identity, &format!("retry: the successor was not adopted: {error:#}"));
                DeadHost::Retry
            }
        };
    }
    // A durable sidecar is the host's record of the child's end; without one
    // the host died with an unknown outcome (invariant 3: its tabs stay).
    let sidecar = crate::terminal_host_runtime::terminal_host_exit_record(record_path)
        .ok()
        .flatten()
        .filter(|(_, exit)| {
            exit.terminal_id == identity.terminal_id && exit.incarnation == identity.incarnation
        });
    probe(
        identity,
        if sidecar.is_some() {
            "a durable exit sidecar: no replacement"
        } else {
            "no exit sidecar"
        },
    );
    #[cfg(unix)]
    if sidecar.is_none()
        && let Some(attachment) =
            replace_host(surface, pty, mux, identity, (record, record_path), scrollback)
    {
        return DeadHost::Replaced(Box::new(attachment));
    }
    probe(identity, "no replacement on the shell: the end of the terminal is recorded");
    let end =
        sidecar.map(|(_, exit)| TerminalEnd::from_host_exit(exit.exit)).unwrap_or_else(|| {
            TerminalEnd::host_lost("terminal host ended without a durable exit sidecar")
        });
    *pty.exit.lock().unwrap_or_else(PoisonError::into_inner) = Some(end);
    mark_hosted_runtime_exited(pty, identity);
    pty.host_connection_state.store(TerminalHostConnectionState::Exited as u8, Ordering::Release);
    pty.stream_progress.notify();
    if let Some(mux) = mux.upgrade() {
        mux.surface_exited(surface.id);
    }
    DeadHost::Stop
}

/// Start a replacement host on the held master, when the terminal is still
/// live in the registry, no shutdown or close is under way and the shell
/// still leads its session. `None` falls back to the host-loss path; the
/// custody it took is then dropped, which hangs up the shell as the dead
/// host's own exit would have.
#[cfg(unix)]
fn replace_host(
    surface: &Arc<Surface>,
    pty: &PtySurface,
    mux: &Weak<Mux>,
    identity: &TerminalHostIdentity,
    (record, record_path): (&TerminalHostRecord, &Path),
    scrollback: usize,
) -> Option<HostAttachment> {
    let Some(mux) = mux.upgrade() else {
        probe(identity, "give up 1: the owner is gone");
        return None;
    };
    let detaching = pty.owner_detaching.load(Ordering::Acquire);
    let dead = pty.dead.load(Ordering::Acquire);
    let has_exit = pty.exit.lock().unwrap_or_else(PoisonError::into_inner).is_some();
    let accepts = mux.terminal_accepts_host_replacement(identity);
    if detaching || dead || has_exit || !accepts {
        probe(
            identity,
            &format!(
                "give up 2: owner_detaching={detaching} dead={dead} exit_is_set={has_exit} \
                 registry_accepts={accepts}"
            ),
        );
        return None;
    }
    let (custody, runtime_kind) =
        match &mut *pty.runtime.lock().unwrap_or_else(PoisonError::into_inner) {
            PtyRuntime::Hosted(host) if host.identity() == *identity => {
                (host.take_pty_custody(), "hosted, this incarnation")
            }
            PtyRuntime::Hosted(_) => (None, "hosted, another incarnation"),
            PtyRuntime::ExitedHosted => (None, "exited"),
            PtyRuntime::Local { .. } => (None, "local"),
        };
    let Some(custody) = custody else {
        probe(identity, &format!("give up 3: no PTY custody is held (runtime: {runtime_kind})"));
        return None;
    };
    if !custody.session_alive() {
        probe(identity, "give up 4: the shell does not lead its session (custody was held)");
        return None;
    }
    let Some(root) = record_path.parent() else {
        probe(identity, "give up 5: the record path has no parent");
        return None;
    };
    let geometry = *pty.geometry.lock().unwrap_or_else(PoisonError::into_inner);
    let options = SurfaceOptions {
        term: mux.host_replacement_term(),
        cols: geometry.cols,
        rows: geometry.rows,
        scrollback,
        ..SurfaceOptions::default()
    };
    let seed = replacement_seed(pty);
    let Ok(owner_token) = crate::terminal_host_runtime::record_owner_token(record) else {
        probe(identity, "give up 6: the owner token of the record is not readable");
        return None;
    };
    let Ok(kitty_graphics_limits) = mux.kitty_image_limits_for_reconnect(surface) else {
        probe(identity, "give up 7: no image limits for the reconnect");
        return None;
    };
    let adoption = TerminalHostAdoption {
        custody: &custody,
        identity: identity.clone(),
        owner_token,
        options: &options,
        default_colors: mux.default_colors(),
        cell_pixels: (geometry.cell_width, geometry.cell_height),
        kitty_graphics_limits,
        seed: &seed,
        host_binary: None,
        fence_wait: Default::default(),
    };
    // The owner's OSC 7501 records, so a daemon that later adopts the
    // replacement keeps them (cx-6so.36.10).
    let records =
        pty.terminal_metadata.lock().unwrap_or_else(PoisonError::into_inner).program_status();
    let program_status = records.lock().unwrap_or_else(PoisonError::into_inner).snapshot();
    let mut attachment =
        match crate::terminal_host_runtime::launch_terminal_host_adopting_with_program_status(
            root,
            adoption,
            Some(program_status),
        ) {
            Ok(attachment) => attachment,
            Err(error) => {
                eprintln!(
                    "cmux-tui: terminal {} kept its host loss: no replacement host: {error:#}",
                    identity.terminal_id
                );
                probe(
                    identity,
                    &format!("give up 8: the launch of the new host failed: {error:#}"),
                );
                return None;
            }
        };
    probe(
        identity,
        &format!("replaced in place: the new host pid is {}", attachment.record.host_pid),
    );
    if !record.workspace_key.is_empty() {
        let _ = attachment.persist_workspace(&record.workspace_key);
    }
    crate::terminal_loss_log::record_host_replaced(
        record_path,
        &identity.terminal_id,
        &identity.incarnation,
        record.host_pid,
        attachment.record.host_pid,
    );
    attachment.keep_pty_custody(custody);
    Some(attachment)
}

/// VT replay of the owner's replica (screen, history, modes, title and
/// working directory) plus its last OSC 9;4 progress, which the replay does
/// not carry. Empty when it cannot fit: the shell then keeps running on a
/// blank screen rather than being lost.
#[cfg(unix)]
fn replacement_seed(pty: &PtySurface) -> Vec<u8> {
    let budget = VT_REPLAY_MAX_BYTES - SEED_HEADROOM_BYTES;
    let Ok(mut seed) =
        pty.term.lock().unwrap_or_else(PoisonError::into_inner).vt_replay_bounded_bytes(budget)
    else {
        return Vec::new();
    };
    let progress = pty
        .terminal_metadata
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .osc_progress()
        .to_owned();
    if !progress.is_empty() {
        seed.extend_from_slice(format!("\x1b]9;{progress}\x1b\\").as_bytes());
    }
    if seed.len() > VT_REPLAY_MAX_BYTES { Vec::new() } else { seed }
}
