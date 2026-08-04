use std::env;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use anyhow::{Context, anyhow, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

const MAX_NATIVE_PAYLOAD_BYTES: u64 = 1024 * 1024;
const MAX_MESSAGE_BYTES: usize = 4 * 1024 * 1024;
const MAX_RESPONSE_BYTES: u64 = 16 * 1024 * 1024;
const SOCKET_TIMEOUT: Duration = Duration::from_millis(800);

#[derive(Debug, PartialEq, Eq)]
struct Args {
    source: String,
    native_event: String,
}

fn main() -> ExitCode {
    let arguments = env::args().skip(1).collect::<Vec<_>>();
    if arguments.iter().any(|argument| matches!(argument.as_str(), "-h" | "--help")) {
        println!("Usage: cmux-tui-hook --source <agent> --event <native-event>");
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
    let socket = match env::var_os("CMUX_TUI_SOCKET").filter(|value| !value.is_empty()) {
        Some(socket) => PathBuf::from(socket),
        None => {
            io::copy(&mut io::stdin().take(MAX_NATIVE_PAYLOAD_BYTES + 1), &mut io::sink())?;
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

fn parse_args(args: impl IntoIterator<Item = String>) -> anyhow::Result<Args> {
    let mut values = args.into_iter();
    let mut source = None;
    let mut native_event = None;
    while let Some(argument) = values.next() {
        match argument.as_str() {
            "--source" if source.is_none() => {
                source = Some(values.next().context("--source requires a value")?);
            }
            "--event" if native_event.is_none() => {
                native_event = Some(values.next().context("--event requires a value")?);
            }
            _ => bail!("unknown or duplicate argument {argument:?}"),
        }
    }
    Ok(Args {
        source: source.context("--source is required")?,
        native_event: native_event.context("--event is required")?,
    })
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
    let request_id = random_prefixed("request")?;
    let request = json!({
        "protocol":"cmux.protocol/1",
        "type":"request",
        "id":request_id,
        "operation":"session.journal.append",
        "params":{"machine":"current","session":"current","event":event},
        "idempotency_key":random_prefixed("mutation")?,
    });
    let mut encoded = serde_json::to_vec(&request)?;
    encoded.push(b'\n');
    if encoded.len() > MAX_MESSAGE_BYTES {
        bail!("agent hook request exceeds the 4 MiB protocol limit");
    }

    let mut stream =
        transport::connect(socket).with_context(|| format!("connect to {}", socket.display()))?;
    stream.set_read_timeout(Some(SOCKET_TIMEOUT))?;
    stream.set_write_timeout(Some(SOCKET_TIMEOUT))?;
    stream.write_all(&encoded)?;
    stream.flush()?;

    let mut response = Vec::new();
    BufReader::new(stream).take(MAX_RESPONSE_BYTES + 2).read_until(b'\n', &mut response)?;
    if response.is_empty() || !response.ends_with(b"\n") {
        bail!("journal append closed without a complete response");
    }
    if response.len() as u64 > MAX_RESPONSE_BYTES {
        bail!("journal append response exceeds 16 MiB");
    }
    let response: Value = serde_json::from_slice(&response)?;
    if response.get("protocol").and_then(Value::as_str) != Some("cmux.protocol/1")
        || response.get("type").and_then(Value::as_str) != Some("response")
    {
        bail!("journal append returned an invalid response envelope");
    }
    if response.get("id").and_then(Value::as_str) != Some(request_id.as_str()) {
        bail!("journal append returned a mismatched request id");
    }
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        let error = response
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .unwrap_or("journal append failed");
        bail!("{error}");
    }
    Ok(())
}

fn random_prefixed(prefix: &str) -> anyhow::Result<String> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes).map_err(|error| anyhow!("allocate {prefix} identity: {error}"))?;
    let mut value = String::with_capacity(prefix.len() + 33);
    value.push_str(prefix);
    value.push('_');
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for byte in bytes {
        value.push(char::from(HEX[usize::from(byte >> 4)]));
        value.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_explicit_source_and_event() {
        assert_eq!(
            parse_args(["--source", "codex", "--event", "Stop"].map(str::to_owned)).unwrap(),
            Args { source: "codex".into(), native_event: "Stop".into() }
        );
    }

    #[test]
    fn invalid_utf8_is_retained_as_base64() {
        let native = read_native_payload(&[0xff, 0x00][..]).unwrap();
        assert_eq!(native, json!({"encoding":"base64","data":"/wA="}));
    }
}
