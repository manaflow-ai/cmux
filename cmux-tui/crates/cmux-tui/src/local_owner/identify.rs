//! One `identify` exchange with the session socket's owner, and the refusal
//! line an owner at its connection limit sends instead of an answer.

use std::io;
use std::io::{BufRead, BufReader, Read, Write};
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use serde_json::Value;

pub(super) const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;

pub(super) enum IdentifyError {
    Timeout,
    /// The owner refused the connection at its connection limit.
    Refused,
    Failed,
}

/// Whether `value` is the refusal an owner at its connection limit sends
/// before it closes a connection (cmux-tui-core `REFUSED_BUSY_LINE`).
fn is_refusal_value(value: &Value) -> bool {
    value.get("protocol").and_then(Value::as_str) == Some("cmux.protocol/2")
        && value.get("type").and_then(Value::as_str) == Some("refused")
        && value.get("code").and_then(Value::as_str) == Some("server.busy")
}

/// `is_refusal_value` for one received line.
pub(super) fn is_refusal(line: &[u8]) -> bool {
    serde_json::from_slice::<Value>(line).is_ok_and(|value| is_refusal_value(&value))
}

/// After a failed write: whether the owner refused the connection. It sends
/// its refusal line before it closes, so the line is already readable.
pub(super) fn refused_after_write(connection: &mut BufReader<Box<dyn transport::Stream>>) -> bool {
    let _ = connection.get_mut().set_read_timeout(Some(Duration::from_millis(200)));
    let mut line = Vec::new();
    connection.by_ref().take(4096).read_until(b'\n', &mut line).is_ok() && is_refusal(&line)
}

/// After a refused socket timeout: whether the owner refused the connection.
/// macOS fails a timeout with EINVAL once the peer has closed, and an owner
/// at its connection limit closes right after its refusal line, which stays
/// readable. A closed connection never blocks this read.
pub(super) fn refused_after_closed(
    connection: &mut BufReader<Box<dyn transport::Stream>>,
    error: &io::Error,
) -> bool {
    if error.kind() != io::ErrorKind::InvalidInput || error.raw_os_error().is_none() {
        return false;
    }
    let mut line = Vec::new();
    connection.by_ref().take(4096).read_until(b'\n', &mut line).is_ok() && is_refusal(&line)
}

fn refused_or_failed(
    connection: &mut BufReader<Box<dyn transport::Stream>>,
    error: &io::Error,
) -> IdentifyError {
    if refused_after_closed(connection, error) {
        IdentifyError::Refused
    } else {
        IdentifyError::Failed
    }
}

/// Run one identify exchange on a fresh connection with a bounded timeout.
pub(super) fn identify(
    stream: Box<dyn transport::Stream>,
    deadline: Instant,
) -> Result<Value, IdentifyError> {
    let timeout =
        Some(deadline.saturating_duration_since(Instant::now()).min(Duration::from_secs(2)));
    let mut connection = BufReader::new(stream);
    let stream = connection.get_ref();
    if let Err(error) =
        stream.set_read_timeout(timeout).and_then(|()| stream.set_write_timeout(timeout))
    {
        return Err(refused_or_failed(&mut connection, &error));
    }
    if writeln!(connection.get_mut(), "{}", serde_json::json!({"id":1,"cmd":"identify"}))
        .and_then(|()| connection.get_mut().flush())
        .is_err()
    {
        // A full owner may close before this write lands.
        return Err(if refused_after_write(&mut connection) {
            IdentifyError::Refused
        } else {
            IdentifyError::Failed
        });
    }
    loop {
        let mut bytes = Vec::new();
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(IdentifyError::Timeout);
        }
        if let Err(error) =
            connection.get_mut().set_read_timeout(Some(remaining.min(Duration::from_secs(2))))
        {
            return Err(refused_or_failed(&mut connection, &error));
        }
        match connection.by_ref().take((RESPONSE_LIMIT + 2) as u64).read_until(b'\n', &mut bytes) {
            Ok(0) => return Err(IdentifyError::Failed),
            Ok(_) => {}
            Err(error)
                if matches!(error.kind(), io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock) =>
            {
                return Err(IdentifyError::Timeout);
            }
            Err(_) => return Err(IdentifyError::Failed),
        }
        if bytes.len() > RESPONSE_LIMIT || !bytes.ends_with(b"\n") {
            return Err(IdentifyError::Failed);
        }
        let Ok(response) = serde_json::from_slice::<Value>(&bytes) else {
            return Err(IdentifyError::Failed);
        };
        if is_refusal_value(&response) {
            return Err(IdentifyError::Refused);
        }
        if response.get("event").is_some() || response["id"] != 1 {
            continue;
        }
        if response["ok"] == true {
            return Ok(response.get("data").cloned().unwrap_or(Value::Null));
        }
        return Err(IdentifyError::Failed);
    }
}

#[cfg(test)]
mod tests {
    use super::is_refusal;

    #[test]
    fn connection_limit_refusal_requires_the_cmux_protocol() {
        assert!(is_refusal(
            br#"{"protocol":"cmux.protocol/2","type":"refused","code":"server.busy"}"#
        ));
        for other_service in [
            br#"{"type":"refused","code":"server.busy"}"#.as_slice(),
            br#"{"protocol":"another.protocol/2","type":"refused","code":"server.busy"}"#,
        ] {
            assert!(!is_refusal(other_service), "an unrelated service must not be replaced");
        }
    }
}
