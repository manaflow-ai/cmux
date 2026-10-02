//! The app host process loop: read [`ToHost`] lines from fd 3, drive the VM,
//! write [`FromHost`] lines back. The only wait is a blocking read whose
//! timeout is the next app timer's due time (no polling: with no timer armed
//! the read blocks until the supervisor writes or closes the socket).

use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::time::{Duration, Instant};

use crate::protocol::{FromHost, MAX_LINE_BYTES, ToHost};
use crate::vm::{AppVm, InitParams, Limits, VmError};

/// Exit codes of the host process.
pub mod exit {
    /// The supervisor closed fd 3 or sent `shutdown`.
    pub const OK: i32 = 0;
    /// A malformed or oversized line, or a message out of order.
    pub const PROTOCOL: i32 = 65;
    /// The VM hit a limit or the engine failed (a `fatal` line was sent first).
    pub const FATAL: i32 = 70;
    /// fd 3 could not be read or written.
    pub const IO: i32 = 74;
    /// The OS sandbox could not be applied.
    pub const SANDBOX: i32 = 77;
}

/// A connection the loop can read with a deadline.
pub trait Channel: std::io::Read {
    fn set_read_deadline(&self, timeout: Option<Duration>) -> std::io::Result<()>;
}

#[cfg(unix)]
impl Channel for std::os::unix::net::UnixStream {
    fn set_read_deadline(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.set_read_timeout(timeout.map(|t| t.max(Duration::from_millis(1))))
    }
}

/// Runs until the supervisor closes the channel, sends `shutdown`, or the VM dies.
pub fn run<R: Channel, W: Write>(read: R, mut write: W, limits: Limits) -> i32 {
    let mut reader = BufReader::new(read);
    let mut vm: Option<AppVm> = None;
    let mut line: Vec<u8> = Vec::new();
    loop {
        let timeout = vm
            .as_ref()
            .and_then(AppVm::next_timer_due)
            .map(|due| due.saturating_duration_since(Instant::now()));
        if reader.get_ref().set_read_deadline(timeout).is_err() {
            return exit::IO;
        }
        match reader.read_until(b'\n', &mut line) {
            Ok(0) if line.is_empty() => return exit::OK,
            Ok(_) if line.last() == Some(&b'\n') => {}
            // End of input in the middle of a line.
            Ok(_) => return exit::PROTOCOL,
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                if line.len() > MAX_LINE_BYTES {
                    return exit::PROTOCOL;
                }
                if let Some(vm) = vm.as_mut() {
                    let fired = vm.fire_due_timers(Instant::now());
                    if let Some(code) = flush(vm, &mut write, fired) {
                        return code;
                    }
                }
                continue;
            }
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => return exit::IO,
        }
        if line.len() > MAX_LINE_BYTES {
            return exit::PROTOCOL;
        }
        let message = match serde_json::from_slice::<ToHost>(&line) {
            Ok(message) => message,
            Err(_) => return exit::PROTOCOL,
        };
        line.clear();
        match (vm.as_mut(), message) {
            (_, ToHost::Shutdown) => return exit::OK,
            (
                None,
                ToHost::Init { app, settings, api_version, ops, known_ops, locale, strings, main },
            ) => {
                let mut created = match AppVm::new(limits) {
                    Ok(created) => created,
                    Err(error) => {
                        let _ = send(&mut write, &FromHost::InitFailed { error });
                        return exit::FATAL;
                    }
                };
                let outcome = created.init(InitParams {
                    app,
                    settings,
                    api_version,
                    ops,
                    known_ops,
                    locale,
                    strings,
                    main,
                });
                let ready = match &outcome {
                    Ok(()) => Some(FromHost::Ready { runtime: runtime_version(&mut created) }),
                    Err(VmError::Init(error)) => {
                        Some(FromHost::InitFailed { error: error.clone() })
                    }
                    Err(VmError::Fatal { .. }) => None,
                };
                let fatal = matches!(outcome, Err(VmError::Fatal { .. }));
                if let Some(code) =
                    flush(&mut created, &mut write, if fatal { outcome } else { Ok(()) })
                {
                    return code;
                }
                if let Some(ready) = ready {
                    if send(&mut write, &ready).is_err() {
                        return exit::IO;
                    }
                    if matches!(ready, FromHost::InitFailed { .. }) {
                        return exit::FATAL;
                    }
                }
                vm = Some(created);
            }
            (None, _) | (Some(_), ToHost::Init { .. }) => return exit::PROTOCOL,
            (Some(vm), message) => {
                let outcome = handle(vm, message, &mut write);
                if let Some(code) = flush(vm, &mut write, outcome) {
                    return code;
                }
                // Steady supervisor traffic never lets the read time out, so
                // timers that came due meanwhile fire here.
                let fired = vm.fire_due_timers(Instant::now());
                if let Some(code) = flush(vm, &mut write, fired) {
                    return code;
                }
            }
        }
    }
}

fn handle<W: Write>(vm: &mut AppVm, message: ToHost, write: &mut W) -> Result<(), VmError> {
    match message {
        ToHost::Mount { mount, export, ctx } => {
            let error = vm.mount(&mount, &export, &ctx)?;
            // Scene ops of the first render go out before `mounted`.
            for message in vm.take_outbox() {
                let _ = send(write, &message);
            }
            let _ = send(write, &FromHost::Mounted { mount, error });
            Ok(())
        }
        ToHost::Unmount { mount } => vm.unmount(&mount),
        ToHost::Dispatch { mount, node, event, payload } => {
            vm.dispatch(&mount, &node, &event, &payload)
        }
        ToHost::Resolve { cb, ok, body } => vm.resolve(cb, ok, &body),
        ToHost::Event { sub, body } => vm.event(sub, &body),
        ToHost::Settings { values } => vm.set_settings(&values),
        ToHost::Run { cb, export, args } => vm.run_command(cb, &export, &args),
        ToHost::Init { .. } | ToHost::Shutdown => Ok(()),
    }
}

/// Writes the outbox; returns an exit code when the loop must end.
fn flush<W: Write>(vm: &mut AppVm, write: &mut W, outcome: Result<(), VmError>) -> Option<i32> {
    for message in vm.take_outbox() {
        if send(write, &message).is_err() {
            return Some(exit::IO);
        }
    }
    match outcome {
        Err(VmError::Fatal { .. }) => Some(exit::FATAL),
        _ => None,
    }
}

fn runtime_version(vm: &mut AppVm) -> String {
    match vm.eval_json("globalThis.__cmuxAppRuntimeVersion") {
        Ok(Ok(serde_json::Value::String(version))) => version,
        _ => String::new(),
    }
}

fn send<W: Write>(write: &mut W, message: &FromHost) -> std::io::Result<()> {
    let mut line = serde_json::to_vec(message).map_err(std::io::Error::other)?;
    line.push(b'\n');
    write.write_all(&line)?;
    write.flush()
}
