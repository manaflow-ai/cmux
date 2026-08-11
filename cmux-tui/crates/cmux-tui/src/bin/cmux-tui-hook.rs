use std::env;
use std::io::{self, BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use anyhow::{Context, anyhow, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

const MAX_NATIVE_PAYLOAD_BYTES: u64 = 1024 * 1024;
const MAX_MESSAGE_BYTES: usize = 4 * 1024 * 1024;
const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const SOCKET_TIMEOUT: Duration = Duration::from_secs(4);

#[derive(Debug, PartialEq, Eq)]
struct Args {
    source: String,
    native_event: String,
}

fn main() -> ExitCode {
    let arguments = env::args().skip(1).collect::<Vec<_>>();
    if arguments.iter().any(|argument| matches!(argument.as_str(), "-h" | "--help")) {
        println!("Usage: cmux-tui-hook <agent> <native-event>");
        return ExitCode::SUCCESS;
    }
    match parse_args(arguments).and_then(run) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-tui-hook: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: Args) -> anyhow::Result<()> {
    if shadowed_by_grok(&args.source, env::var_os("GROK_HOOK_EVENT").as_deref()) {
        drain_native_payload()?;
        return Ok(());
    }
    let socket = match env::var_os("CMUX_TUI_SOCKET").filter(|value| !value.is_empty()) {
        Some(socket) => PathBuf::from(socket),
        None => {
            drain_native_payload()?;
            return Ok(());
        }
    };
    let terminal = env::var("CMUX_TUI_TERMINAL_ID").ok().filter(|value| !value.is_empty());
    let native = read_native_payload(io::stdin().lock())?;
    let ingress = cmux_tui_core::agent_hook_journal_ingress(
        &args.source,
        &args.native_event,
        terminal.as_deref(),
        native,
    )?;
    let event = serde_json::to_value(ingress)?;
    append(&socket, event)
}

fn shadowed_by_grok(source: &str, grok_hook_event: Option<&std::ffi::OsStr>) -> bool {
    matches!(source, "claude" | "cursor") && grok_hook_event.is_some_and(|value| !value.is_empty())
}

fn drain_native_payload() -> io::Result<()> {
    io::copy(&mut io::stdin().take(MAX_NATIVE_PAYLOAD_BYTES + 1), &mut io::sink()).map(|_| ())
}

fn parse_args(args: impl IntoIterator<Item = String>) -> anyhow::Result<Args> {
    let mut values = args.into_iter();
    let source = values.next().context("agent source is required")?;
    let native_event = values.next().context("native event is required")?;
    if let Some(extra) = values.next() {
        bail!("unexpected argument {extra:?}");
    }
    anyhow::ensure!(!source.is_empty(), "agent source cannot be empty");
    anyhow::ensure!(!native_event.is_empty(), "native event cannot be empty");
    Ok(Args { source, native_event })
}

fn read_native_payload(reader: impl Read) -> anyhow::Result<Value> {
    let mut bytes = Vec::new();
    reader.take(MAX_NATIVE_PAYLOAD_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_NATIVE_PAYLOAD_BYTES {
        bail!("agent hook payload exceeds 1048576 bytes");
    }
    if bytes.is_empty() {
        return Ok(json!({}));
    }
    if let Ok(value) = serde_json::from_slice(&bytes) {
        return Ok(value);
    }
    if let Ok(text) = String::from_utf8(bytes.clone()) {
        return Ok(json!({"encoding":"utf8","data":text}));
    }
    Ok(json!({"encoding":"base64","data":BASE64.encode(bytes)}))
}

fn append(socket: &Path, event: Value) -> anyhow::Result<()> {
    let (request_id, idempotency_key) = random_identifiers()?;
    let request = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":request_id,
        "operation":"session.journal.append",
        "params":{"machine":"current","session":"current","event":event},
        "idempotency_key":idempotency_key,
    });
    let mut encoded = serde_json::to_vec(&request)?;
    encoded.push(b'\n');
    if encoded.len() > MAX_MESSAGE_BYTES {
        bail!("agent hook request exceeds the 4 MiB protocol limit");
    }

    retry_until(SOCKET_TIMEOUT, |deadline| append_once(socket, &encoded, &request_id, deadline))
}

#[derive(Debug)]
enum AppendAttemptError {
    Retryable(anyhow::Error),
    Fatal(anyhow::Error),
}

fn retry_until<T>(
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

fn append_once(
    socket: &Path,
    encoded: &[u8],
    request_id: &str,
    deadline: Instant,
) -> Result<(), AppendAttemptError> {
    let mut stream = connect_before(socket, deadline)?;
    write_before(&mut *stream, encoded, deadline)?;
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

fn remaining_before(deadline: Instant) -> Result<Duration, AppendAttemptError> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        Err(AppendAttemptError::Retryable(anyhow!("journal append deadline expired")))
    } else {
        Ok(remaining)
    }
}

fn connect_before(
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

fn write_before(
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
        stream
            .set_write_timeout(Some(remaining_before(deadline)?))
            .map_err(|error| AppendAttemptError::Retryable(error.into()))?;
        match stream.flush() {
            Ok(()) => return Ok(()),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(AppendAttemptError::Retryable(error.into())),
        }
    }
}

fn read_before(
    stream: Box<dyn transport::Stream>,
    deadline: Instant,
) -> Result<Vec<u8>, AppendAttemptError> {
    let mut reader = BufReader::new(stream);
    let mut response = Vec::new();
    loop {
        reader
            .get_ref()
            .set_read_timeout(Some(remaining_before(deadline)?))
            .map_err(|error| AppendAttemptError::Retryable(error.into()))?;
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

fn random_identifiers() -> anyhow::Result<(String, String)> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes).map_err(|error| anyhow!("allocate hook identity: {error}"))?;
    let mut suffix = String::with_capacity(32);
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for byte in bytes {
        suffix.push(char::from(HEX[usize::from(byte >> 4)]));
        suffix.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    Ok((format!("request_{suffix}"), format!("mutation_{suffix}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_short_positional_source_and_event() {
        assert_eq!(
            parse_args(["codex", "Stop"].map(str::to_owned)).unwrap(),
            Args { source: "codex".into(), native_event: "Stop".into() }
        );
    }

    #[test]
    fn grok_compatibility_events_are_deduplicated_inside_the_helper() {
        use std::ffi::OsStr;

        assert!(shadowed_by_grok("claude", Some(OsStr::new("Stop"))));
        assert!(shadowed_by_grok("cursor", Some(OsStr::new("stop"))));
        assert!(!shadowed_by_grok("codex", Some(OsStr::new("Stop"))));
        assert!(!shadowed_by_grok("claude", None));
    }

    #[test]
    fn invalid_utf8_is_retained_as_base64() {
        let native = read_native_payload(&[0xff, 0x00][..]).unwrap();
        assert_eq!(native, json!({"encoding":"base64","data":"/wA="}));
    }

    #[test]
    fn retries_transient_admission_loss_within_one_bounded_receipt_window() {
        let mut attempts = 0;
        retry_until(Duration::from_millis(100), |_| {
            attempts += 1;
            if attempts < 3 {
                Err(AppendAttemptError::Retryable(anyhow!("connection dropped")))
            } else {
                Ok(())
            }
        })
        .unwrap();
        assert_eq!(attempts, 3);
    }

    #[test]
    fn does_not_retry_a_durable_rejection() {
        let mut attempts = 0;
        let error = retry_until(Duration::from_millis(100), |_| {
            attempts += 1;
            Err::<(), _>(AppendAttemptError::Fatal(anyhow!("invalid event")))
        })
        .unwrap_err();
        assert_eq!(attempts, 1);
        assert_eq!(error.to_string(), "invalid event");
    }

    #[test]
    fn missing_session_socket_is_immediately_inactive() {
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("missing.sock");
        let result = append_once(
            &socket,
            b"{}\n",
            "request_missing_socket",
            Instant::now() + Duration::from_millis(100),
        );

        assert!(matches!(result, Err(AppendAttemptError::Fatal(_))));
    }
}
