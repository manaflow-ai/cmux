//! Explicit escape for the private pre-v1 control protocol.
//!
//! This module is intentionally named `raw`: its request object may contain
//! internal fields and receives no public compatibility guarantees.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::time::Duration;

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::MAX_MESSAGE_BYTES;
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

#[derive(Clone, Debug)]
pub(super) struct RawCommandPlan {
    pub request: Value,
}

pub(super) fn run(global: GlobalArgs, plan: RawCommandPlan) -> i32 {
    let expected_id = plan.request.get("id").cloned();
    let encoded = match serde_json::to_vec(&plan.request) {
        Ok(encoded) if encoded.len() <= MAX_MESSAGE_BYTES => encoded,
        Ok(_) => {
            eprintln!("cmux: raw request exceeds the 4 MiB protocol limit");
            return 2;
        }
        Err(error) => {
            eprintln!("cmux: cannot encode raw request: {error}");
            return 2;
        }
    };
    let socket = match resolve_socket(&global) {
        Ok(socket) => socket,
        Err(_) => {
            eprintln!("{}", crate::localization::catalog().startup.invalid_session_name);
            return 2;
        }
    };
    let stream = match transport::connect(&socket) {
        Ok(stream) => stream,
        Err(error) => {
            eprintln!("cannot connect to session socket {}: {error}", socket.display());
            return 3;
        }
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let mut reader = BufReader::new(stream);
    if let Err(error) = reader
        .get_mut()
        .write_all(&encoded)
        .and_then(|_| reader.get_mut().write_all(b"\n"))
        .and_then(|_| reader.get_mut().flush())
    {
        eprintln!("transport error: {error}");
        return 3;
    }
    loop {
        let line = match read_line_limited(&mut reader) {
            Ok(None) => {
                eprintln!("transport closed before response");
                return 3;
            }
            Ok(Some(line)) => line,
            Err(error) => {
                eprintln!("{error}");
                return 3;
            }
        };
        let value: Value = match serde_json::from_str(&line) {
            Ok(value) => value,
            Err(error) => {
                eprintln!("protocol error: invalid raw JSON response: {error}");
                return 3;
            }
        };
        if value.get("event").is_some() {
            if matches!(global.output, OutputMode::Json | OutputMode::JsonLines)
                && super::wire::print_local_success(&value, global.output) != 0
            {
                return 3;
            }
            continue;
        }
        if expected_id.as_ref().is_some_and(|id| value.get("id") != Some(id)) {
            continue;
        }
        if value.get("ok").and_then(Value::as_bool) == Some(true) {
            return super::wire::print_local_success(
                value.get("data").unwrap_or(&Value::Null),
                global.output,
            );
        }
        let error = json!({
            "code": value
                .get("error_code")
                .and_then(Value::as_str)
                .unwrap_or("raw.command_failed"),
            "message": value
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("raw command failed"),
            "details": value,
            "retryable": false
        });
        return super::wire::print_local_error(&error, global.output, 1);
    }
}

fn read_line_limited(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
) -> Result<Option<String>, String> {
    const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;
    let mut bytes = Vec::new();
    match reader.by_ref().take((RESPONSE_LIMIT + 2) as u64).read_until(b'\n', &mut bytes) {
        Ok(0) => return Ok(None),
        Ok(_) => {}
        Err(error)
            if matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) =>
        {
            return Err(format!("transport timed out before raw response: {error}"));
        }
        Err(error) => return Err(format!("transport error: {error}")),
    }
    if bytes.len() > RESPONSE_LIMIT {
        return Err("protocol error: raw response exceeds the 16 MiB limit".into());
    }
    if !bytes.ends_with(b"\n") {
        return Err("transport closed with a partial raw JSON line".into());
    }
    bytes.pop();
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    String::from_utf8(bytes)
        .map(Some)
        .map_err(|error| format!("protocol error: raw response is not UTF-8: {error}"))
}

fn resolve_socket(global: &GlobalArgs) -> anyhow::Result<PathBuf> {
    Ok(super::wire::resolve_socket_with_origin(global)?.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_plan_keeps_the_exact_private_object() {
        let request = json!({"id": 7, "cmd": "private-operation", "opaque": {"x": true}});
        let plan = RawCommandPlan { request: request.clone() };
        assert_eq!(plan.request, request);
    }

    #[test]
    fn explicit_session_precedes_ambient_socket_fallbacks() {
        let global = GlobalArgs { session: Some("session-alpha".into()), ..GlobalArgs::default() };
        let socket = super::super::wire::resolve_socket_with_env(&global, |_| {
            Some("/tmp/stale.sock".into())
        })
        .expect("session socket path should resolve");

        assert_eq!(
            socket.0,
            cmux_tui_core::server::try_default_socket_path("session-alpha")
                .expect("session socket path should resolve")
        );
    }
}
