//! One journal append over the session socket: connect, write the request
//! line, read the receipt, and retry a transient failure until the hook
//! child's `SOCKET_TIMEOUT`.

use super::*;

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
    let mut current = std::borrow::Cow::Borrowed(encoded);
    retry_until(SOCKET_TIMEOUT, |deadline| {
        match append_once(socket, &current, request_id, deadline, on_sent) {
            Err(AppendAttemptError::Fatal(error))
                if error.to_string().contains("unknown parameters") =>
            {
                match without_live_prompt(&current) {
                    Some(stripped) => {
                        current = std::borrow::Cow::Owned(stripped);
                        Err(AppendAttemptError::Retryable(error))
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
    Retryable(anyhow::Error),
    Fatal(anyhow::Error),
}

pub(super) fn retry_until<T>(
    timeout: Duration,
    mut attempt: impl FnMut(Instant) -> Result<T, AppendAttemptError>,
) -> anyhow::Result<T> {
    let deadline = Instant::now() + timeout;
    let mut last_error = None;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            let error = last_error.unwrap_or_else(|| anyhow!("journal append timed out"));
            return Err(error).context(format!(
                "journal append was not acknowledged within {} ms",
                timeout.as_millis()
            ));
        }
        match attempt(deadline) {
            Ok(value) => return Ok(value),
            Err(AppendAttemptError::Fatal(error)) => return Err(error),
            Err(AppendAttemptError::Retryable(error)) => {
                last_error = Some(error);
                // Admission reopens as short-lived clients finish. Yielding lets
                // the server make progress without adding a timer to hook paths.
                std::thread::yield_now();
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
    write_before(&mut *stream, encoded, deadline)?;
    on_sent();
    let response = read_before(stream, deadline)?;
    let response: Value = serde_json::from_slice(&response)
        .map_err(|error| AppendAttemptError::Fatal(error.into()))?;
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
        let error = anyhow!(error.to_owned());
        return Err(
            if response
                .get("error")
                .and_then(|error| error.get("retryable"))
                .and_then(Value::as_bool)
                == Some(true)
            {
                AppendAttemptError::Retryable(error)
            } else {
                AppendAttemptError::Fatal(error)
            },
        );
    }
    Ok(())
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
