//! One journal append over the session socket: connect, write the request
//! line, read the receipt, and retry a transient failure until the hook
//! child's `SOCKET_TIMEOUT`.
//!
//! Retries follow the clients' one policy, `RetryBudget` (full-jitter
//! exponential backoff that honours the daemon's `retry_after_ms`, inside the
//! total bound). A daemon at its connection limit answers with its busy line
//! (`type: "refused"`, `server.busy`); that is a retry, never a lost event.

use cmux_tui_core::backoff::RetryBudget;

use super::*;

/// The most the first retry waits, beyond the daemon's `retry_after_ms`. A
/// hook connection holds its slot for one request (milliseconds), so slots
/// free up within this; the draw spreads hooks refused together over it.
const RETRY_INITIAL: Duration = Duration::from_millis(100);
/// The most one retry waits, beyond the daemon's `retry_after_ms`, so the
/// `SOCKET_TIMEOUT` bound still holds several tries.
const RETRY_MAX: Duration = Duration::from_secs(1);

/// Sends the request and waits for the journal receipt, retrying until
/// `SOCKET_TIMEOUT`. `on_sent` runs each time the full request has been
/// written to the server, so the parent can stop waiting for ordering.
pub(super) fn append_with_receipt(
    socket: &Path,
    request_id: &str,
    encoded: &[u8],
    on_sent: &dyn Fn(),
) -> anyhow::Result<()> {
    // A daemon from before `live_prompt` refuses unknown parameters: the event goes once more
    // without the prompt, so a version skew never loses a turn start (the prompt is optional).
    // That resend is not a load retry, so it goes at once, inside the same try.
    let mut current = std::borrow::Cow::Borrowed(encoded);
    retry_until(SOCKET_TIMEOUT, |deadline| {
        match append_once(socket, &current, request_id, deadline, on_sent) {
            Err(AppendAttemptError::Fatal(error))
                if error.to_string().contains("unknown parameters") =>
            {
                match without_live_prompt(&current) {
                    Some(stripped) => {
                        current = std::borrow::Cow::Owned(stripped);
                        append_once(socket, &current, request_id, deadline, on_sent)
                    }
                    None => Err(AppendAttemptError::Fatal(error)),
                }
            }
            other => other,
        }
    })
}

/// `encoded` (one request line) without its memory-only fields (`live_prompt`, `live_reply`,
/// `live_question`); nil when it has none.
pub(super) fn without_live_prompt(encoded: &[u8]) -> Option<Vec<u8>> {
    let mut request: Value = serde_json::from_slice(encoded).ok()?;
    let params = request.get_mut("params")?.as_object_mut()?;
    let removed = ["live_prompt", "live_reply", "live_question"]
        .into_iter()
        .filter(|field| params.remove(*field).is_some())
        .count();
    if removed == 0 {
        return None;
    }
    let mut line = serde_json::to_vec(&request).ok()?;
    line.push(b'\n');
    Some(line)
}

#[derive(Debug)]
pub(super) enum AppendAttemptError {
    /// The request may go again; a [`Busy`] inside carries the daemon's
    /// `retry_after_ms`.
    Retryable(anyhow::Error),
    Fatal(anyhow::Error),
}

/// The daemon refused the request before it read it (its busy line, or a
/// retryable error answer), and said when to try again.
#[derive(Debug)]
pub(super) struct Busy {
    message: String,
    retry_after: Option<Duration>,
}

impl Busy {
    /// A refusal with its `message` and the daemon's `retry_after_ms`, if any.
    fn from_reply(message: &str, retry_after_ms: Option<&Value>) -> Self {
        Self {
            message: message.to_owned(),
            retry_after: retry_after_ms.and_then(Value::as_u64).map(Duration::from_millis),
        }
    }
}

impl std::fmt::Display for Busy {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for Busy {}

pub(super) fn retry_until<T>(
    timeout: Duration,
    mut attempt: impl FnMut(Instant) -> Result<T, AppendAttemptError>,
) -> anyhow::Result<T> {
    // `timeout` is a liveness bound of the detached child (the provider's
    // tool call stopped waiting at the handoff), not a correctness timer.
    let mut retries = RetryBudget::until(RETRY_INITIAL, RETRY_MAX, Instant::now() + timeout);
    let deadline = retries.deadline();
    loop {
        match attempt(deadline) {
            Ok(value) => return Ok(value),
            Err(AppendAttemptError::Fatal(error)) => return Err(error),
            Err(AppendAttemptError::Retryable(error)) => {
                let retry_after = error.downcast_ref::<Busy>().and_then(|busy| busy.retry_after);
                if !retries.sleep(retry_after) {
                    return Err(error).context(format!(
                        "journal append was not acknowledged within {} ms",
                        timeout.as_millis()
                    ));
                }
            }
        }
    }
}

pub(super) fn append_once(
    socket: &Path,
    encoded: &[u8],
    request_id: &str,
    deadline: Instant,
    on_sent: &dyn Fn(),
) -> Result<(), AppendAttemptError> {
    let mut stream = connect_before(socket, deadline)?;
    // Bound the receipt read now, while the peer is surely still connected:
    // once a server has answered and closed, macOS refuses SO_RCVTIMEO with
    // EINVAL although the answer is still readable.
    stream
        .set_read_timeout(Some(remaining_before(deadline)?))
        .map_err(|error| AppendAttemptError::Retryable(error.into()))?;
    if let Err(error) = write_before(&mut *stream, encoded, deadline) {
        return Err(busy_line_after_failed_write(stream, deadline, &error).unwrap_or(error));
    }
    on_sent();
    let response = read_before(stream, deadline)?;
    let response: Value = serde_json::from_slice(&response)
        .map_err(|error| AppendAttemptError::Fatal(error.into()))?;
    if let Some(busy) = busy_line(&response) {
        return Err(AppendAttemptError::Retryable(busy.into()));
    }
    if response.get("protocol").and_then(Value::as_str) != Some("cmux.protocol/2")
        || response.get("type").and_then(Value::as_str) != Some("response")
    {
        return Err(AppendAttemptError::Fatal(anyhow!(
            "journal append returned an invalid response envelope"
        )));
    }
    if response.get("id").and_then(Value::as_str) != Some(request_id) {
        return Err(AppendAttemptError::Fatal(anyhow!(
            "journal append returned a mismatched request id"
        )));
    }
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        let error = response
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .unwrap_or("journal append failed");
        let details = response.get("error").and_then(|error| error.get("details"));
        return Err(
            if response
                .get("error")
                .and_then(|error| error.get("retryable"))
                .and_then(Value::as_bool)
                == Some(true)
            {
                let retry_after_ms = details.and_then(|details| details.get("retry_after_ms"));
                AppendAttemptError::Retryable(Busy::from_reply(error, retry_after_ms).into())
            } else {
                AppendAttemptError::Fatal(anyhow!(error.to_owned()))
            },
        );
    }
    Ok(())
}

/// The daemon's busy line (`server/listen.rs` `REFUSED_BUSY_LINE`): it is at
/// its connection limit, read nothing, and closed.
fn busy_line(reply: &Value) -> Option<Busy> {
    (reply.get("protocol").and_then(Value::as_str) == Some("cmux.protocol/2")
        && reply.get("type").and_then(Value::as_str) == Some("refused"))
    .then(|| {
        let message = reply.get("message").and_then(Value::as_str).unwrap_or("the session is busy");
        Busy::from_reply(message, reply.get("retry_after_ms"))
    })
}

/// A daemon at its limit writes the busy line and closes at once, so the
/// request's write may fail with a broken pipe while the busy line, and its
/// `retry_after_ms`, still waits to be read. Only a closed peer is read here:
/// the read then cannot block.
fn busy_line_after_failed_write(
    stream: Box<dyn transport::Stream>,
    deadline: Instant,
    error: &AppendAttemptError,
) -> Option<AppendAttemptError> {
    let AppendAttemptError::Retryable(error) = error else {
        return None;
    };
    let closed = error.downcast_ref::<io::Error>().is_some_and(|error| {
        matches!(error.kind(), io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset)
    });
    if !closed {
        return None;
    }
    let line = read_before(stream, deadline).ok()?;
    let busy = busy_line(&serde_json::from_slice(&line).ok()?)?;
    Some(AppendAttemptError::Retryable(busy.into()))
}

pub(super) fn remaining_before(deadline: Instant) -> Result<Duration, AppendAttemptError> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        Err(AppendAttemptError::Retryable(anyhow!("journal append deadline expired")))
    } else {
        Ok(remaining)
    }
}

pub(super) fn connect_before(
    socket: &Path,
    deadline: Instant,
) -> Result<Box<dyn transport::Stream>, AppendAttemptError> {
    let remaining = remaining_before(deadline)?;
    let socket = socket.to_path_buf();
    let display = socket.display().to_string();
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    let connector = std::thread::Builder::new()
        .name("journal-hook-connect".into())
        .spawn(move || {
            let _ = sender.send(transport::connect(&socket));
        })
        .map_err(|error| AppendAttemptError::Retryable(error.into()))?;
    let result = match receiver.recv_timeout(remaining) {
        Ok(result) => {
            let _ = connector.join();
            result
        }
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            let _ = connector.join();
            return Err(AppendAttemptError::Retryable(anyhow!(
                "journal socket connector stopped without a result"
            )));
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            // This helper is a short-lived process. Dropping the join handle is
            // safe here because retry_until immediately reaches the same final
            // deadline and main exits, which terminates the blocked connector.
            drop(connector);
            return Err(AppendAttemptError::Retryable(anyhow!("connect to {display} timed out")));
        }
    };
    result.map_err(|error| {
        let transient = matches!(
            error.kind(),
            io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
        );
        let error = anyhow!(error).context(format!("connect to {display}"));
        if transient {
            AppendAttemptError::Retryable(error)
        } else {
            // No listener means this terminal is no longer attached to a live
            // cmux-tui. Retrying a stale path only delays synchronous providers.
            AppendAttemptError::Fatal(error)
        }
    })
}

pub(super) fn write_before(
    stream: &mut dyn transport::Stream,
    encoded: &[u8],
    deadline: Instant,
) -> Result<(), AppendAttemptError> {
    let mut offset = 0;
    while offset < encoded.len() {
        stream
            .set_write_timeout(Some(remaining_before(deadline)?))
            .map_err(|error| AppendAttemptError::Retryable(error.into()))?;
        match stream.write(&encoded[offset..]) {
            Ok(0) => {
                return Err(AppendAttemptError::Retryable(
                    io::Error::from(io::ErrorKind::WriteZero).into(),
                ));
            }
            Ok(written) => offset += written,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(AppendAttemptError::Retryable(error.into())),
        }
    }
    loop {
        // The request is fully written. A fast server may already have
        // answered and closed, which makes macOS refuse the option; the
        // timeout set for the writes still bounds the flush.
        let _ = stream.set_write_timeout(Some(remaining_before(deadline)?));
        match stream.flush() {
            Ok(()) => return Ok(()),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(AppendAttemptError::Retryable(error.into())),
        }
    }
}

pub(super) fn read_before(
    stream: Box<dyn transport::Stream>,
    deadline: Instant,
) -> Result<Vec<u8>, AppendAttemptError> {
    let mut reader = BufReader::new(stream);
    let mut response = Vec::new();
    loop {
        // Shrink the bound toward the deadline. A refusal means the server
        // already closed (macOS EINVAL), so the read cannot block; the
        // timeout set before the request was written still applies.
        let _ = reader.get_ref().set_read_timeout(Some(remaining_before(deadline)?));
        let available =
            reader.fill_buf().map_err(|error| AppendAttemptError::Retryable(error.into()))?;
        if available.is_empty() {
            return Err(AppendAttemptError::Retryable(anyhow!(
                "journal append closed without a complete response"
            )));
        }
        let consumed = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |newline| newline + 1);
        if response.len().saturating_add(consumed) > MAX_RESPONSE_BYTES {
            return Err(AppendAttemptError::Fatal(anyhow!(
                "journal append response exceeds 16 MiB"
            )));
        }
        let complete = available[consumed - 1] == b'\n';
        response.extend_from_slice(&available[..consumed]);
        reader.consume(consumed);
        if complete {
            return Ok(response);
        }
    }
}

#[cfg(all(test, unix))]
#[path = "journal_append_tests.rs"]
mod tests;
