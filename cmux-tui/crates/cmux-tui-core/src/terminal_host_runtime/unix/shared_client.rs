//! One client connection of a shared host, on its event loop
//! (`shared_exec.rs`) instead of an input thread and a writer thread.
//!
//! The handshake, snapshot and `Ready` ran already (`serve_client`, as a
//! job). From then on the input side is a serial job that each socket
//! readiness runs: it reads what arrived without blocking (`MSG_DONTWAIT`,
//! so the descriptor stays blocking for the writer), cuts complete frames
//! and applies them in order with the same [`ClientInput::handle`] the
//! input thread uses. The writer side is a serial job that every queued
//! frame wakes (`HostTap::wake`); it writes the frames in order with the
//! same blocking, time-bounded writes as the writer thread, and ends at the
//! same frames.

use std::os::fd::AsRawFd;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, TryRecvError};

use super::super::shared::host_serve::{ClientInput, InputFlow};
use super::super::shared::host_state::HostTap;
use super::super::sys::HostStream;
use super::shared_exec::{Executor, SerialJob};
use super::*;
use crate::terminal_host_protocol::HEADER_LEN;

pub(crate) struct Connection {
    pub(crate) input: ClientInput,
    pub(crate) stream: HostStream,
    pub(crate) receiver: Receiver<Frame>,
    pub(crate) tap: HostTap,
    pub(crate) writer_job: Arc<SerialJob>,
    /// The launch-owner claim and the active-stream count, released when
    /// the writer ends, as when the writer thread returned.
    pub(crate) keep: Box<dyn Send>,
}

pub(crate) fn serve(executor: &'static Executor, connection: Connection) -> std::io::Result<()> {
    let Connection { input, stream, receiver, tap, writer_job, keep } = connection;
    let input_stream = stream.try_clone()?;
    let host = input.host.clone();
    let client = input.client;

    let mut writer = Some((stream, receiver, tap, keep));
    writer_job.install(
        executor,
        shared::host_crash::attribute(move || {
            let Some((stream, receiver, tap, _)) = writer.as_mut() else { return false };
            loop {
                // What ends the writer, and whether the socket is shut down.
                let ended = match receiver.try_recv() {
                    Ok(frame)
                        if frame.kind == MessageKind::ResyncRequired && frame.sequence == 0 =>
                    {
                        tap.release(&frame);
                        Some(false)
                    }
                    Ok(frame) => {
                        let written = write_frame(stream, &frame);
                        tap.release(&frame);
                        match written {
                            // A client that stopped reading must not keep an
                            // ended terminal alive through its input side: shut
                            // the socket down, so the input job reads EOF (a
                            // one-terminal host's process exit did that).
                            Err(_) => Some(true),
                            Ok(()) if frame.kind == MessageKind::Exit => Some(false),
                            Ok(()) => None,
                        }
                    }
                    Err(TryRecvError::Empty) => return true,
                    Err(TryRecvError::Disconnected) => Some(false),
                };
                if let Some(shut_down) = ended {
                    host.remove_client(client);
                    if shut_down {
                        tap.close();
                    }
                    if let Some((stream, receiver, tap, keep)) = writer.take() {
                        // As the writer thread's frame: its guards first.
                        drop(keep);
                        drop((stream, receiver, tap));
                    }
                    return false;
                }
            }
        }),
    );

    let fd = input_stream.as_raw_fd();
    let input_job = SerialJob::new();
    let wake = input_job.clone();
    let mut state = Some((input_stream, Vec::new(), input, None::<u64>));
    input_job.install(
        executor,
        shared::host_crash::attribute(move || {
            let Some((stream, buffer, input, token)) = state.as_mut() else { return false };
            match pump(stream, buffer, input) {
                None => {
                    let wake = wake.clone();
                    *token = executor.on_readable(fd, move || wake.wake(executor)).ok();
                    if token.is_some() {
                        return true;
                    }
                    // Not watchable: end the connection as on a read error.
                    input.end(false);
                }
                Some(detached) => {
                    if let Some(token) = token.take() {
                        executor.forget(fd, token);
                    }
                    input.end(detached);
                }
            }
            state.take();
            false
        }),
    );
    Ok(())
}

/// Read what arrived and apply every complete frame. `None`: wait for
/// more; `Some(detached)`: the input side ended.
fn pump(stream: &HostStream, buffer: &mut Vec<u8>, input: &ClientInput) -> Option<bool> {
    let mut chunk = [0u8; 64 * 1024];
    let mut ended = false;
    let mut read = 0usize;
    // One pass reads at most about one maximal frame; the level-triggered
    // re-arm runs the next pass at once, so a client that writes as fast as
    // the host reads cannot grow the buffer without bound.
    while read < MAX_FRAME_PAYLOAD {
        // SAFETY: a valid buffer; MSG_DONTWAIT keeps the shared descriptor
        // blocking for the writer.
        let count = unsafe {
            libc::recv(
                stream.as_raw_fd(),
                chunk.as_mut_ptr().cast(),
                chunk.len(),
                libc::MSG_DONTWAIT,
            )
        };
        if count > 0 {
            buffer.extend_from_slice(&chunk[..count.unsigned_abs()]);
            read += count.unsigned_abs();
            continue;
        }
        if count == 0 {
            ended = true;
            break;
        }
        match std::io::Error::last_os_error().kind() {
            std::io::ErrorKind::Interrupted => continue,
            std::io::ErrorKind::WouldBlock => break,
            _ => {
                ended = true;
                break;
            }
        }
    }
    loop {
        match next_frame(buffer) {
            Ok(Some(frame)) => match input.handle(frame) {
                InputFlow::Continue => {}
                InputFlow::Stop => return Some(false),
                InputFlow::Detached => return Some(true),
            },
            Ok(None) => break,
            Err(_) => return Some(false),
        }
    }
    ended.then_some(false)
}

/// The next complete frame at the front of `buffer`, with the checks of
/// `read_frame`.
fn next_frame(buffer: &mut Vec<u8>) -> anyhow::Result<Option<Frame>> {
    if buffer.len() < HEADER_LEN {
        return Ok(None);
    }
    let length = u32::from_le_bytes([buffer[12], buffer[13], buffer[14], buffer[15]]) as usize;
    if length > MAX_FRAME_PAYLOAD {
        anyhow::bail!("terminal-host frame payload is too large");
    }
    let total = HEADER_LEN + length;
    if buffer.len() < total {
        return Ok(None);
    }
    let frame = read_frame(&mut &buffer[..total], MAX_FRAME_PAYLOAD)?
        .ok_or_else(|| anyhow::anyhow!("terminal-host frame vanished"))?;
    buffer.drain(..total);
    Ok(Some(frame))
}
