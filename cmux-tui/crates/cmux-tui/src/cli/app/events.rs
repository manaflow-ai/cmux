//! `cmux app events`: one `events.stream` request, then each event line the
//! app sends is printed until the app or the reader stops. Kept out of app.rs
//! for its line budget.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

use serde_json::{Value, json};

use super::super::OutputMode;
use super::{failure, send_line};

/// `events.stream`: one JSON event per line until the app closes the
/// stream or this process is interrupted. Blocking reads, no polling.
pub(super) fn stream_events(stream: &mut UnixStream, params: Value, output: OutputMode) -> i32 {
    if let Err(error) =
        send_line(stream, &json!({ "id": 1, "method": "events.stream", "params": params }))
    {
        return failure("app.transport", &error, output, 3);
    }
    let reader = match stream.try_clone() {
        Ok(reader) => BufReader::new(reader),
        Err(error) => return failure("app.transport", &error.to_string(), output, 3),
    };
    let mut stdout = std::io::stdout().lock();
    for line in reader.lines() {
        let Ok(line) = line else { return 3 };
        let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
        if value.get("ok").and_then(Value::as_bool) == Some(false) {
            let error = value.get("error").cloned().unwrap_or(Value::Null);
            return super::super::wire::print_local_error(&error, output, 1);
        }
        let written = match output {
            OutputMode::Quiet => Ok(()),
            _ => writeln!(stdout, "{line}").and_then(|()| stdout.flush()),
        };
        if written.is_err() {
            return 0;
        }
    }
    0
}
