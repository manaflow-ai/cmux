//! Host terminal ownership: the terminal restore guard, host keyboard
//! enhancement protocol negotiation, terminal restore, and the renderer panic
//! catch.

use std::io::Write;
use std::panic::AssertUnwindSafe;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

#[cfg(test)]
use crossbeam_channel::Sender as SyncSender;
use crossterm::ExecutableCommand;
#[cfg(test)]
use crossterm::event::Event;
use crossterm::event::{
    DisableBracketedPaste, DisableFocusChange, DisableMouseCapture, KeyboardEnhancementFlags,
    PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
};
use crossterm::terminal::{
    LeaveAlternateScreen, disable_raw_mode, query_keyboard_enhancement_flags_with_timeout,
};

#[cfg(test)]
use crate::app::events::AppEvent;
use crate::app::host_input::HostInputShutdown;
use crate::localization;
use crate::ui::graphics_writer::{GraphicsWriterShutdown, StdoutLock};

pub(super) struct TerminalRestoreGuard {
    pub(super) stdout_lock: Arc<StdoutLock>,
    pub(super) host_keyboard_protocol: HostKeyboardProtocolOwnership,
    pub(super) host_input_shutdown: Option<HostInputShutdown>,
    pub(super) graphics_shutdown: Option<GraphicsWriterShutdown>,
    pub(super) armed: bool,
}

impl TerminalRestoreGuard {
    pub(super) fn new(stdout_lock: Arc<StdoutLock>) -> Self {
        Self {
            stdout_lock,
            host_keyboard_protocol: HostKeyboardProtocolOwnership::default(),
            host_input_shutdown: None,
            graphics_shutdown: None,
            armed: true,
        }
    }

    pub(super) fn host_keyboard_protocol(&self) -> &HostKeyboardProtocolOwnership {
        &self.host_keyboard_protocol
    }

    pub(super) fn host_keyboard_protocol_mut(&mut self) -> &mut HostKeyboardProtocolOwnership {
        &mut self.host_keyboard_protocol
    }

    pub(super) fn set_graphics_shutdown(
        &mut self,
        graphics_shutdown: Option<GraphicsWriterShutdown>,
    ) {
        self.graphics_shutdown = graphics_shutdown;
    }

    pub(super) fn set_host_input_shutdown(&mut self, host_input_shutdown: HostInputShutdown) {
        self.host_input_shutdown = Some(host_input_shutdown);
    }

    pub(super) fn restore(&mut self) -> anyhow::Result<()> {
        if !self.armed {
            return Ok(());
        }
        self.armed = false;
        if let Some(host_input_shutdown) = &self.host_input_shutdown {
            host_input_shutdown.shutdown();
        }
        if let Some(graphics_shutdown) = &self.graphics_shutdown {
            graphics_shutdown.cancel_and_wait();
        }
        let result = restore_terminal(Some(&self.stdout_lock), &self.host_keyboard_protocol);
        // The terminal is the user's again; diagnostics from here on must
        // reach it instead of the client log. Explicit restoration disarms
        // the guard, so Drop will not do this (idempotent regardless).
        crate::client_log::restore_stderr_from_log();
        result
    }

    pub(super) fn restore_after_error(&mut self, error: anyhow::Error) -> anyhow::Error {
        match self.restore() {
            Ok(()) => error,
            Err(restore_error) => terminal_restore_error(error, restore_error),
        }
    }
}

pub(super) fn terminal_restore_error(
    error: anyhow::Error,
    restore_error: anyhow::Error,
) -> anyhow::Error {
    let error = format!("{error:#}");
    let restore_error = format!("{restore_error:#}");
    anyhow::anyhow!(
        localization::catalog().runtime.terminal_restore_also_failed(&error, &restore_error)
    )
}

impl Drop for TerminalRestoreGuard {
    fn drop(&mut self) {
        if self.armed {
            self.armed = false;
            if let Some(host_input_shutdown) = &self.host_input_shutdown {
                host_input_shutdown.shutdown();
            }
            if let Some(graphics_shutdown) = &self.graphics_shutdown {
                graphics_shutdown.cancel_and_wait();
            }
            with_panic_stdout_lock(&self.stdout_lock, || {
                let _ = restore_terminal_unlocked(&self.host_keyboard_protocol);
            });
            // The terminal is the user's again; exit-time diagnostics should
            // reach it instead of the client log.
            crate::client_log::restore_stderr_from_log();
        }
    }
}

#[derive(Clone, Debug)]
pub(super) struct HostKeyboardProtocolOwnership {
    // Panic and normal cleanup share this claim. The stdout lock serializes
    // restore attempts, and the first successful pop consumes ownership.
    pushed: Arc<AtomicBool>,
}

impl Default for HostKeyboardProtocolOwnership {
    fn default() -> Self {
        Self { pushed: Arc::new(AtomicBool::new(false)) }
    }
}

impl PartialEq for HostKeyboardProtocolOwnership {
    fn eq(&self, other: &Self) -> bool {
        self.is_pushed() == other.is_pushed()
    }
}

impl Eq for HostKeyboardProtocolOwnership {}

impl HostKeyboardProtocolOwnership {
    fn pushed() -> Self {
        Self { pushed: Arc::new(AtomicBool::new(true)) }
    }

    pub(super) fn is_pushed(&self) -> bool {
        self.pushed.load(Ordering::Acquire)
    }
}

pub(super) const HOST_KEYBOARD_FLAGS: KeyboardEnhancementFlags =
    KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES
        .union(KeyboardEnhancementFlags::REPORT_ALTERNATE_KEYS)
        .union(KeyboardEnhancementFlags::REPORT_ALL_KEYS_AS_ESCAPE_CODES)
        .union(KeyboardEnhancementFlags::REPORT_ASSOCIATED_TEXT);
pub(super) const HOST_KEYBOARD_QUERY_TIMEOUT: Duration = Duration::from_millis(150);

pub(super) fn keyboard_protocol_accepts(
    requested: KeyboardEnhancementFlags,
    accepted: Option<KeyboardEnhancementFlags>,
) -> bool {
    accepted.is_some_and(|flags| flags.contains(requested))
}

pub(super) fn enable_host_keyboard_protocol(
    stdout: &mut impl Write,
) -> std::io::Result<HostKeyboardProtocolOwnership> {
    let result = stdout.execute(PushKeyboardEnhancementFlags(HOST_KEYBOARD_FLAGS));
    match result {
        Ok(_) => Ok(HostKeyboardProtocolOwnership::pushed()),
        Err(error) if error.kind() == std::io::ErrorKind::Unsupported => {
            Ok(HostKeyboardProtocolOwnership::default())
        }
        Err(error) => Err(error),
    }
}

pub(super) fn negotiate_host_keyboard_protocol(
    stdout: &mut impl Write,
    ownership: &mut HostKeyboardProtocolOwnership,
) -> std::io::Result<()> {
    negotiate_host_keyboard_protocol_with(
        stdout,
        ownership,
        query_keyboard_enhancement_flags_with_timeout,
    )
}

pub(super) fn negotiate_host_keyboard_protocol_with(
    stdout: &mut impl Write,
    ownership: &mut HostKeyboardProtocolOwnership,
    query: impl FnOnce(Duration) -> std::io::Result<Option<KeyboardEnhancementFlags>>,
) -> std::io::Result<()> {
    let enabled = enable_host_keyboard_protocol(stdout)?;
    ownership.pushed.store(enabled.is_pushed(), Ordering::Release);
    if !ownership.is_pushed() {
        return Ok(());
    }

    if keyboard_protocol_accepts(
        HOST_KEYBOARD_FLAGS,
        query(HOST_KEYBOARD_QUERY_TIMEOUT).ok().flatten(),
    ) {
        return Ok(());
    }

    disable_host_keyboard_protocol(stdout, ownership)?;
    Ok(())
}

pub(super) fn disable_host_keyboard_protocol(
    stdout: &mut impl Write,
    ownership: &HostKeyboardProtocolOwnership,
) -> std::io::Result<()> {
    if ownership.pushed.swap(false, Ordering::AcqRel)
        && let Err(error) = stdout.execute(PopKeyboardEnhancementFlags)
    {
        ownership.pushed.store(true, Ordering::Release);
        return Err(error);
    }
    Ok(())
}

pub(super) fn restore_terminal(
    stdout_lock: Option<&Arc<StdoutLock>>,
    host_keyboard_protocol: &HostKeyboardProtocolOwnership,
) -> anyhow::Result<()> {
    let _guard = stdout_lock.map(|lock| lock.lock());
    if let Some(stdout_lock) = stdout_lock
        && let Err(error) = stdout_lock.recover_stream_locked()
    {
        let _ = disable_raw_mode();
        return Err(error.into());
    }
    restore_terminal_unlocked(host_keyboard_protocol)
}

pub(super) fn with_panic_stdout_lock(stdout_lock: &Arc<StdoutLock>, restore: impl FnOnce()) {
    // Render panics may recurse on the owner thread. Reentrant acquisition
    // preserves that path while still waiting for a different stdout writer.
    let _guard = stdout_lock.lock();
    if stdout_lock.recover_stream_locked().is_ok() {
        restore();
    } else {
        let _ = disable_raw_mode();
    }
}

pub(super) fn restore_terminal_unlocked(
    host_keyboard_protocol: &HostKeyboardProtocolOwnership,
) -> anyhow::Result<()> {
    let mut stdout = std::io::stdout();
    // A canceled or failed graphics write may have ended inside a Kitty APC.
    // CAN returns the outer parser to ground before any restoration sequence.
    let _ = stdout.write_all(&[0x18]);
    // A standalone ST is harmless after CAN and closes hosts that retain a
    // string despite cancellation.
    let _ = write!(stdout, "\x1b\\");
    // Reset the mouse pointer shape in case we left it as a hand.
    let _ = write!(stdout, "\x1b]22;default\x07");
    // Cursor color and DECSCUSR shape are outer-terminal global state. Always
    // restore both, including panic/startup-failure paths.
    let _ = write!(stdout, "\x1b]112\x07\x1b[0 q");
    // Restore the conventional host behavior where Shift bypasses capture.
    let _ = write!(stdout, "\x1b[>0s");
    let _ = disable_host_keyboard_protocol(&mut stdout, host_keyboard_protocol);
    let _ = stdout.execute(DisableBracketedPaste);
    let _ = stdout.execute(DisableFocusChange);
    let _ = stdout.execute(DisableMouseCapture);
    let _ = stdout.execute(LeaveAlternateScreen);
    disable_raw_mode()?;
    Ok(())
}

#[cfg(test)]
pub(super) fn forward_host_input(
    mut read: impl FnMut() -> std::io::Result<Event>,
    input_tx: &SyncSender<AppEvent>,
) {
    loop {
        match read() {
            Ok(event) => {
                if input_tx.send(AppEvent::Input(event)).is_err() {
                    return;
                }
            }
            Err(error) => {
                let _ = input_tx.send(AppEvent::HostInputFailed(error.to_string()));
                return;
            }
        }
    }
}

pub(super) fn catch_renderer_panic<T>(render: impl FnOnce() -> T) -> anyhow::Result<T> {
    std::panic::catch_unwind(AssertUnwindSafe(render)).map_err(|payload| {
        let message = payload
            .downcast_ref::<String>()
            .map(String::as_str)
            .or_else(|| payload.downcast_ref::<&str>().copied())
            .unwrap_or(localization::catalog().runtime.unknown_panic);
        anyhow::anyhow!(localization::catalog().runtime.renderer_panicked(message))
    })
}
