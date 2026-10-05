//! Hosted surface view of the clipboard-read broker: the read the terminal
//! host is asking this surface's user about, and the one answer to it. The
//! daemon broker (layer 3) decides who may answer; nothing here logs or keeps
//! clipboard text.

use std::sync::Arc;

use ghostty_vt::ClipboardReadRequest;

use super::{PtyRuntime, Surface};
use crate::server::clipboard_read::{HostRead, HostSignal};
use crate::terminal_host_runtime::{ClipboardReadSignal, HostAttachment};

impl Surface {
    /// Routes the current host connection's clipboard reads to the daemon
    /// broker as they arrive, on that connection's frame reader thread. Runs
    /// at spawn and again for each replacement connection. Answers go
    /// through the connection's own replier, so a refusal never waits on the
    /// runtime lock and a read never outlives its connection.
    pub(super) fn install_clipboard_read_handler(surface: &Arc<Surface>) {
        let Some(pty) = surface.as_pty() else { return };
        let Some((responses, replier)) =
            surface.with_host(|host| (host.control_responses(), host.clipboard_replier()))
        else {
            return;
        };
        let id = pty.meta.id;
        let terminal = surface.terminal_public_id().map(|terminal| terminal.as_str().to_string());
        let mux = pty.mux.clone();
        responses.set_clipboard_read_handler(Arc::new(move |signal| {
            let signal = match signal {
                ClipboardReadSignal::Request(request) => {
                    let replier = replier.clone();
                    HostSignal::Request(HostRead {
                        surface: id,
                        terminal: terminal.clone(),
                        token: request.token,
                        location: request.location,
                        complete: Box::new(move |text| {
                            replier.complete(request.token, text.as_deref()).unwrap_or(false)
                        }),
                    })
                }
                ClipboardReadSignal::Cancel(token) => HostSignal::Cancel { surface: id, token },
            };
            match (mux.upgrade(), signal) {
                (Some(mux), signal) => mux.control_clients.clipboard_reads.handle(signal),
                (None, HostSignal::Request(read)) => {
                    let _ = (read.complete)(None);
                }
                (None, HostSignal::Cancel { .. }) => {}
            }
        }));
    }

    fn with_host<T>(&self, f: impl FnOnce(&HostAttachment) -> T) -> Option<T> {
        let pty = self.as_pty()?;
        let runtime = pty.runtime.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        match &*runtime {
            PtyRuntime::Hosted(host) => Some(f(host)),
            _ => None,
        }
    }

    /// Whether this surface's host connection negotiated clipboard reads.
    pub fn clipboard_reads_negotiated(&self) -> bool {
        self.with_host(HostAttachment::clipboard_reads_negotiated).unwrap_or(false)
    }

    /// The clipboard read the host is waiting on, if any.
    pub fn pending_clipboard_read(&self) -> Option<ClipboardReadRequest> {
        self.with_host(HostAttachment::pending_clipboard_read).flatten()
    }

    /// Answers the pending read `token`: `Some(text)` grants it, `None`
    /// refuses it. False, with nothing sent, when `token` is not pending
    /// (answered, replaced, or the connection changed).
    pub fn complete_clipboard_read(
        &self,
        token: u64,
        text: Option<Vec<u8>>,
    ) -> std::io::Result<bool> {
        self.with_host(|host| host.complete_clipboard_read(token, text.as_deref()))
            .unwrap_or(Ok(false))
    }
}

#[cfg(test)]
pub(crate) mod test_fixture {
    use std::os::unix::net::UnixStream;
    use std::sync::Arc;
    use std::time::Duration;

    use super::super::{HostedSurfaceLaunch, PtyLifetime};
    use super::Surface;
    use crate::resource::TerminalPublicId;
    use crate::{Mux, SurfaceOptions};

    /// A hosted surface for `terminal` on a negotiated fake host connection,
    /// and the host's end of it.
    pub(crate) fn hosted_surface_for_clipboard_test(
        mux: &Arc<Mux>,
        terminal: TerminalPublicId,
    ) -> (Arc<Surface>, UnixStream) {
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        let (mut attachment, host) = crate::terminal_host_runtime::input_ack_surface_fixture();
        attachment.negotiate_clipboard_reads_for_test();
        let terminal_id = attachment.record.terminal_id.clone();
        attachment.record.workspace_key = workspace.key.clone();
        mux.seed_launching_terminal_for_test(&terminal_id, &workspace.key).unwrap();
        let surface = Surface::spawn_hosted(
            1,
            SurfaceOptions::default(),
            Arc::downgrade(mux),
            HostedSurfaceLaunch {
                attachment,
                kitty_reservation: None,
                terminate_on_error: false,
                defer_launch_activation: false,
                lifetime: PtyLifetime::SessionOwned,
                terminal_public_id: Some(terminal),
                resource_identity: None,
            },
        )
        .unwrap();
        host.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        host.set_write_timeout(Some(Duration::from_secs(2))).unwrap();
        (surface, host)
    }
}
