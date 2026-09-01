use std::io::{BufRead, BufReader, Read, Write};
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug)]
pub(super) struct ServerPlan {
    pub action: ServerAction,
    pub session: Option<String>,
}

#[derive(Clone, Debug)]
pub(super) enum ServerAction {
    Status,
    Ensure,
    Stop { force: bool },
    ReloadConfig,
}

pub(super) fn run(mut global: GlobalArgs, plan: ServerPlan) -> i32 {
    if global.machine.is_some() {
        return usage_error(
            crate::localization::catalog().local_server.machine_not_supported,
            global.output,
        );
    }
    if let Some(session) = plan.session {
        if global.session.as_deref().is_some_and(|global| global != session) {
            return usage_error(
                crate::localization::catalog().local_server.session_conflict,
                global.output,
            );
        }
        global.session = Some(session);
    }
    if let Some(session) = global.session.as_deref()
        && !valid_session_name(session)
    {
        return usage_error(
            crate::localization::catalog().machine_agent.invalid_session,
            global.output,
        );
    }
    let expected_session = global.session.clone();
    let (socket, socket_is_derived) = match super::wire::resolve_socket_with_origin(&global) {
        Ok(resolved) => resolved,
        Err(_error) => {
            if let Some(session) = global.session.as_deref()
                && cmux_tui_core::server::validate_session_name(session).is_err()
            {
                return local_error_with_details(
                    "usage.invalid",
                    crate::localization::catalog().local_server.invalid_session,
                    json!({"reason": "invalid_session"}),
                    global.output,
                    2,
                );
            }
            return local_error_with_details(
                "server.unavailable",
                crate::localization::catalog().local_server.connect_failed,
                json!({"reason": "socket_path_unavailable"}),
                global.output,
                3,
            );
        }
    };
    let socket_output = socket.to_string_lossy().into_owned();
    if matches!(plan.action, ServerAction::Ensure) {
        return run_ensure(
            expected_session,
            socket,
            socket_output,
            socket_is_derived,
            global.output,
        );
    }
    let stream = match transport::connect(&socket) {
        Ok(stream) => stream,
        Err(error) if matches!(plan.action, ServerAction::Stop { .. }) && is_absent(&error) => {
            return print_success(
                json!({
                    "status":"not_running",
                    "session":expected_session,
                    "socket":socket_output,
                    "message":crate::localization::catalog().local_server.not_running,
                }),
                global.output,
            );
        }
        Err(_) => {
            return local_error(
                "server.unavailable",
                crate::localization::catalog().local_server.connect_failed,
                global.output,
                3,
            );
        }
    };
    let mut connection = BufReader::new(stream);
    let deadline = Instant::now() + Duration::from_secs(10);
    let identity = match exchange(&mut connection, json!({"id":1,"cmd":"identify"}), deadline) {
        Ok(identity) => identity,
        Err(_) => {
            return local_error(
                "server.identity_failed",
                crate::localization::catalog().local_server.identity_failed,
                global.output,
                3,
            );
        }
    };
    if identity["app"] != "cmux-tui" {
        return local_error(
            "server.wrong_owner",
            crate::localization::catalog().local_server.wrong_owner,
            global.output,
            1,
        );
    }
    match identity.get("lifecycle_ready") {
        Some(Value::Bool(true)) | None => {}
        Some(Value::Bool(false)) => {
            return local_error(
                "server.unavailable",
                crate::localization::catalog().local_server.starting,
                global.output,
                3,
            );
        }
        Some(_) => {
            return local_error(
                "server.invalid_identity",
                crate::localization::catalog().local_server.invalid_identity,
                global.output,
                3,
            );
        }
    }
    let actual_session = identity["session"].as_str().unwrap_or_default();
    if actual_session.is_empty() {
        return local_error(
            "server.invalid_identity",
            crate::localization::catalog().local_server.invalid_identity,
            global.output,
            3,
        );
    }
    let Some(pid) = identity["pid"].as_u64().and_then(|pid| u32::try_from(pid).ok()) else {
        return local_error(
            "server.invalid_identity",
            crate::localization::catalog().local_server.invalid_identity,
            global.output,
            3,
        );
    };
    let Some(generation) = identity["generation"].as_str().filter(|value| !value.is_empty()) else {
        return local_error(
            "server.invalid_identity",
            crate::localization::catalog().local_server.invalid_identity,
            global.output,
            3,
        );
    };
    if expected_session.as_deref().is_some_and(|expected| actual_session != expected) {
        return local_error(
            "server.different_session",
            crate::localization::catalog().local_server.different_session,
            global.output,
            1,
        );
    }

    match plan.action {
        ServerAction::Ensure => unreachable!("ensure returns before the lifecycle exchange"),
        ServerAction::Status => print_success(
            json!({
                "status":"running",
                "session":actual_session,
                "socket":socket_output,
                "pid":pid,
                "generation":generation,
                "message":crate::localization::catalog().local_server.running,
            }),
            global.output,
        ),
        ServerAction::ReloadConfig => {
            let result =
                match exchange(&mut connection, json!({"id":2,"cmd":"reload-config"}), deadline) {
                    Ok(result) => result,
                    Err(ExchangeError::Rejected) => {
                        return local_error(
                            "server.reload_failed",
                            crate::localization::catalog().local_server.reload_rejected,
                            global.output,
                            1,
                        );
                    }
                    Err(_) => {
                        return local_error(
                            "server.reload_failed",
                            crate::localization::catalog().local_server.communication_failed,
                            global.output,
                            3,
                        );
                    }
                };
            if result["reloaded"].as_bool() != Some(true) {
                return local_error(
                    "server.invalid_response",
                    crate::localization::catalog().local_server.invalid_response,
                    global.output,
                    3,
                );
            };
            print_success(
                json!({
                    "reloaded":true,
                    "session":actual_session,
                    "warnings":result["warnings"].as_array().cloned().unwrap_or_default(),
                    "message":crate::localization::catalog().local_server.reloaded,
                }),
                global.output,
            )
        }
        ServerAction::Stop { force } => {
            if force
                && !identity["capabilities"].as_array().is_some_and(|values| {
                    values.iter().any(|value| value == "daemon-handoff-force-v1")
                })
            {
                return local_error(
                    "server.force_unsupported",
                    crate::localization::catalog().local_server.force_unsupported,
                    global.output,
                    1,
                );
            }
            let result = match exchange(
                &mut connection,
                json!({
                    "id":2,
                    "cmd":"shutdown-daemon",
                    "pid":pid,
                    "generation":generation,
                    "force":force,
                }),
                deadline,
            ) {
                Ok(result) => result,
                Err(ExchangeError::Rejected) => {
                    return local_error(
                        "server.stop_failed",
                        crate::localization::catalog().local_server.stop_rejected,
                        global.output,
                        1,
                    );
                }
                Err(_) => {
                    return local_error(
                        "server.stop_failed",
                        crate::localization::catalog().local_server.communication_failed,
                        global.output,
                        3,
                    );
                }
            };
            if result["accepted"] != true {
                return local_error(
                    "server.invalid_response",
                    crate::localization::catalog().local_server.invalid_response,
                    global.output,
                    3,
                );
            }
            if let Err(message) = wait_for_close(&mut connection, deadline) {
                return local_error("server.stop_incomplete", &message, global.output, 3);
            }
            print_success(
                json!({
                    "status":"stopped",
                    "accepted":true,
                    "session":actual_session,
                    "pid":pid,
                    "generation":generation,
                    "message":crate::localization::catalog().local_server.stopped,
                }),
                global.output,
            )
        }
    }
}

/// `server ensure`: connect to a ready owner, spawning a detached one when
/// nothing serves the socket. Reports `running` for an owner that already
/// existed and `started` for one this call spawned.
fn run_ensure(
    expected_session: Option<String>,
    socket: std::path::PathBuf,
    socket_output: String,
    socket_is_derived: bool,
    output: OutputMode,
) -> i32 {
    let messages = &crate::localization::catalog().local_server;
    let spec = crate::local_owner::OwnerSpec {
        session: expected_session.clone().unwrap_or_else(|| "main".to_string()),
        socket,
        socket_is_derived,
        state: None,
        term: None,
    };
    let deadline = Instant::now() + crate::local_owner::ENSURE_DEADLINE;
    match crate::local_owner::ensure_owner(&spec, expected_session.as_deref(), deadline) {
        Ok(ensured) => {
            let (status, message, ready) = match &ensured {
                crate::local_owner::Ensured::Running(ready) => ("running", messages.running, ready),
                crate::local_owner::Ensured::Started(ready) => ("started", messages.started, ready),
            };
            print_success(
                json!({
                    "status":status,
                    "session":ready.session,
                    "socket":socket_output,
                    "pid":ready.pid,
                    "generation":ready.generation,
                    "message":message,
                }),
                output,
            )
        }
        Err(crate::local_owner::EnsureError::Spawn(_error)) => {
            local_error("server.spawn_failed", &messages.owner_spawn_failed(), output, 3)
        }
        Err(crate::local_owner::EnsureError::NotReady) => {
            local_error("server.unavailable", messages.owner_not_ready, output, 3)
        }
        Err(crate::local_owner::EnsureError::WrongOwner) => {
            local_error("server.wrong_owner", messages.wrong_owner, output, 1)
        }
        Err(crate::local_owner::EnsureError::DifferentSession) => {
            local_error("server.different_session", messages.different_session, output, 1)
        }
        Err(crate::local_owner::EnsureError::InvalidIdentity) => {
            local_error("server.invalid_identity", messages.invalid_identity, output, 3)
        }
        Err(crate::local_owner::EnsureError::UnsupportedProtocol) => {
            local_error("server.unsupported_protocol", messages.unsupported_protocol, output, 3)
        }
    }
}

fn valid_session_name(session: &str) -> bool {
    !session.is_empty()
        && session.len() <= 64
        && session.chars().all(|character| !character.is_control() && !character.is_whitespace())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ExchangeError {
    Transport,
    Timeout,
    Closed,
    InvalidResponse,
    Rejected,
}

fn exchange(
    connection: &mut BufReader<Box<dyn transport::Stream>>,
    request: Value,
    deadline: Instant,
) -> Result<Value, ExchangeError> {
    require_time_remaining(connection, deadline)?;
    writeln!(connection.get_mut(), "{request}")
        .and_then(|()| connection.get_mut().flush())
        .map_err(exchange_io_error)?;
    loop {
        let Some(response) = read_response(connection, deadline)? else {
            return Err(ExchangeError::Closed);
        };
        if response.get("event").is_some() || response["id"] != request["id"] {
            continue;
        }
        if response["ok"] == true {
            return Ok(response.get("data").cloned().unwrap_or(Value::Null));
        }
        return Err(ExchangeError::Rejected);
    }
}

fn read_response(
    connection: &mut BufReader<Box<dyn transport::Stream>>,
    deadline: Instant,
) -> Result<Option<Value>, ExchangeError> {
    require_time_remaining(connection, deadline)?;
    let mut bytes = Vec::new();
    match connection.by_ref().take((RESPONSE_LIMIT + 2) as u64).read_until(b'\n', &mut bytes) {
        Ok(0) => return Ok(None),
        Ok(_) => {}
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
            ) =>
        {
            return Err(ExchangeError::Timeout);
        }
        Err(error) => return Err(exchange_io_error(error)),
    }
    if bytes.len() > RESPONSE_LIMIT || !bytes.ends_with(b"\n") {
        return Err(ExchangeError::InvalidResponse);
    }
    bytes.pop();
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    serde_json::from_slice(&bytes).map(Some).map_err(|_| ExchangeError::InvalidResponse)
}

fn require_time_remaining(
    connection: &mut BufReader<Box<dyn transport::Stream>>,
    deadline: Instant,
) -> Result<(), ExchangeError> {
    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
        return Err(ExchangeError::Timeout);
    };
    if remaining.is_zero() {
        return Err(ExchangeError::Timeout);
    }
    connection
        .get_mut()
        .set_read_timeout(Some(remaining))
        .and_then(|()| connection.get_mut().set_write_timeout(Some(remaining)))
        .map_err(exchange_io_error)
}

fn exchange_io_error(error: std::io::Error) -> ExchangeError {
    if matches!(error.kind(), std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock) {
        ExchangeError::Timeout
    } else if matches!(
        error.kind(),
        std::io::ErrorKind::BrokenPipe
            | std::io::ErrorKind::ConnectionAborted
            | std::io::ErrorKind::ConnectionReset
            | std::io::ErrorKind::NotConnected
            | std::io::ErrorKind::UnexpectedEof
    ) {
        ExchangeError::Closed
    } else {
        ExchangeError::Transport
    }
}

fn is_absent(error: &std::io::Error) -> bool {
    matches!(error.kind(), std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused)
}

fn wait_for_close(
    connection: &mut BufReader<Box<dyn transport::Stream>>,
    deadline: Instant,
) -> Result<(), String> {
    loop {
        match read_response(connection, deadline) {
            Ok(None) => return Ok(()),
            Ok(Some(event)) => {
                if event.get("event").is_some() {
                    continue;
                }
                return Err(crate::localization::catalog()
                    .local_server
                    .unexpected_after_stop
                    .to_string());
            }
            Err(ExchangeError::Closed | ExchangeError::Transport) => return Ok(()),
            Err(error) => {
                let messages = &crate::localization::catalog().local_server;
                return Err(if error == ExchangeError::Timeout {
                    messages.stop_timeout.to_string()
                } else {
                    messages.communication_failed.to_string()
                });
            }
        }
    }
}

fn usage_error(message: &str, output: OutputMode) -> i32 {
    local_error("usage.invalid", message, output, 2)
}

fn local_error(code: &str, message: &str, output: OutputMode, exit_code: i32) -> i32 {
    local_error_with_details(code, message, json!({}), output, exit_code)
}

fn local_error_with_details(
    code: &str,
    message: &str,
    details: Value,
    output: OutputMode,
    exit_code: i32,
) -> i32 {
    super::wire::print_local_error(
        &json!({"code":code,"message":message,"details":details,"retryable":false}),
        output,
        exit_code,
    )
}

fn print_success(value: Value, output: OutputMode) -> i32 {
    super::wire::print_local_success(&value, output)
}

#[cfg(test)]
mod tests {
    use std::io::{self, Read, Write};
    use std::net::Shutdown;
    use std::sync::{Arc, Mutex};

    use super::*;

    #[test]
    fn rejects_invalid_session_names_before_socket_resolution() {
        assert!(!valid_session_name(""));
        assert!(!valid_session_name("bad name"));
        assert!(!valid_session_name("bad\nname"));
        assert!(!valid_session_name(&"x".repeat(65)));
    }

    #[test]
    fn accepts_session_names_for_explicit_and_default_socket_routes() {
        assert!(valid_session_name("main"));
        assert!(valid_session_name("agent-1"));
    }

    struct UnreadableStream;

    impl Read for UnreadableStream {
        fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
            panic!("an expired lifecycle deadline must fail before reading")
        }
    }

    impl Write for UnreadableStream {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl transport::Stream for UnreadableStream {
        fn try_clone_box(&self) -> io::Result<Box<dyn transport::Stream>> {
            Ok(Box::new(Self))
        }

        fn set_read_timeout(&self, _: Option<Duration>) -> io::Result<()> {
            Ok(())
        }

        fn set_write_timeout(&self, _: Option<Duration>) -> io::Result<()> {
            Ok(())
        }

        fn shutdown(&self, _: Shutdown) -> io::Result<()> {
            Ok(())
        }
    }

    struct TimeoutRecordingStream {
        read_timeout: Arc<Mutex<Option<Duration>>>,
        write_timeout: Arc<Mutex<Option<Duration>>>,
    }

    impl Read for TimeoutRecordingStream {
        fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
            Ok(0)
        }
    }

    impl Write for TimeoutRecordingStream {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl transport::Stream for TimeoutRecordingStream {
        fn try_clone_box(&self) -> io::Result<Box<dyn transport::Stream>> {
            Ok(Box::new(Self {
                read_timeout: self.read_timeout.clone(),
                write_timeout: self.write_timeout.clone(),
            }))
        }

        fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
            *self.read_timeout.lock().unwrap() = timeout;
            Ok(())
        }

        fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
            *self.write_timeout.lock().unwrap() = timeout;
            Ok(())
        }

        fn shutdown(&self, _: Shutdown) -> io::Result<()> {
            Ok(())
        }
    }

    struct TransportCloseStream;

    impl Read for TransportCloseStream {
        fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
            Err(io::Error::other("transport closed after shutdown acknowledgement"))
        }
    }

    impl Write for TransportCloseStream {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl transport::Stream for TransportCloseStream {
        fn try_clone_box(&self) -> io::Result<Box<dyn transport::Stream>> {
            Ok(Box::new(Self))
        }

        fn set_read_timeout(&self, _: Option<Duration>) -> io::Result<()> {
            Ok(())
        }

        fn set_write_timeout(&self, _: Option<Duration>) -> io::Result<()> {
            Ok(())
        }

        fn shutdown(&self, _: Shutdown) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn expired_deadline_fails_before_reading_another_frame() {
        let stream: Box<dyn transport::Stream> = Box::new(UnreadableStream);
        let mut connection = BufReader::new(stream);
        let expired = Instant::now() - Duration::from_millis(1);

        assert_eq!(read_response(&mut connection, expired), Err(ExchangeError::Timeout));
    }

    #[test]
    fn lifecycle_deadline_bounds_reads_and_writes() {
        let read_timeout = Arc::new(Mutex::new(None));
        let write_timeout = Arc::new(Mutex::new(None));
        let stream: Box<dyn transport::Stream> = Box::new(TimeoutRecordingStream {
            read_timeout: read_timeout.clone(),
            write_timeout: write_timeout.clone(),
        });
        let mut connection = BufReader::new(stream);
        let requested = Duration::from_secs(1);

        require_time_remaining(&mut connection, Instant::now() + requested).unwrap();

        let read_timeout = read_timeout.lock().unwrap().unwrap();
        let write_timeout = write_timeout.lock().unwrap().unwrap();
        assert!(!read_timeout.is_zero());
        assert!(read_timeout <= requested);
        assert!(!write_timeout.is_zero());
        assert!(write_timeout <= requested);
    }

    #[test]
    fn stop_accepts_transport_close_after_shutdown_acknowledgement() {
        let stream: Box<dyn transport::Stream> = Box::new(TransportCloseStream);
        let mut connection = BufReader::new(stream);

        assert!(wait_for_close(&mut connection, Instant::now() + Duration::from_secs(1)).is_ok());
    }

    #[test]
    fn lifecycle_io_errors_preserve_timeout_classification() {
        assert_eq!(
            exchange_io_error(io::Error::from(io::ErrorKind::TimedOut)),
            ExchangeError::Timeout
        );
        assert_eq!(
            exchange_io_error(io::Error::from(io::ErrorKind::WouldBlock)),
            ExchangeError::Timeout
        );
        assert_eq!(
            exchange_io_error(io::Error::from(io::ErrorKind::BrokenPipe)),
            ExchangeError::Closed
        );
        assert_eq!(
            exchange_io_error(io::Error::from(io::ErrorKind::ConnectionReset)),
            ExchangeError::Closed
        );
        assert_eq!(
            exchange_io_error(io::Error::from(io::ErrorKind::NotConnected)),
            ExchangeError::Closed
        );
        assert_eq!(
            exchange_io_error(io::Error::from(io::ErrorKind::Other)),
            ExchangeError::Transport
        );
    }
}
