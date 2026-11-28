//! `cmux computer-use record`: a display recorded to an MP4 file.
//!
//! `record --out FILE --seconds N` is one process from start to finished
//! file: it starts the recording with N as its cap, waits, and stops it, so
//! no call outlives a transport's timeout and a killed CLI leaves a
//! recording that ends by itself. `record start` and `record stop --out
//! FILE` are the same two halves for a script that does work in between;
//! nothing is held open between them.

use std::io::Write as _;
use std::time::Duration;

use base64::Engine as _;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::{GlobalArgs, Outcome, caller, new_call_id, print, with_machine};

/// What `record` was asked to do.
#[derive(Debug, Clone, PartialEq)]
pub(in crate::cli) enum RecordRequest {
    /// Record for `seconds` and save the file.
    Whole { out: String, seconds: f64, options: Value, machine: Option<String> },
    /// Start one and return.
    Start { options: Value, machine: Option<String> },
    /// Stop the running one (or `id`) and save the file.
    Stop { out: String, id: Option<String>, machine: Option<String> },
}

pub(super) const USAGE: &str = "usage: cmux computer-use record --out FILE --seconds N [--display ID] [--fps N] [--max-edge PX] [--machine M]\n       cmux computer-use record start [--max-seconds N] [--display ID] [--fps N] [--max-edge PX] [--machine M]\n       cmux computer-use record stop --out FILE [--id RECORDING] [--machine M]";

fn number(flag: &str, text: &str) -> Result<f64, String> {
    match text.parse::<f64>() {
        Ok(n) if n.is_finite() && n > 0.0 => Ok(n),
        _ => Err(format!("{flag} needs a number above 0, not {text:?}")),
    }
}

fn whole(flag: &str, text: &str) -> Result<u64, String> {
    text.parse::<u64>().map_err(|_| format!("{flag} needs a whole number, not {text:?}"))
}

pub(super) fn parse(rest: &[&str]) -> Result<RecordRequest, String> {
    let (verb, rest) = match rest.split_first() {
        Some((&"start", rest)) => ("start", rest),
        Some((&"stop", rest)) => ("stop", rest),
        _ => ("whole", rest),
    };
    let allowed: &[&str] = match verb {
        "start" => &["--max-seconds", "--display", "--fps", "--max-edge", "--machine"],
        "stop" => &["--out", "--id", "--machine"],
        _ => &["--out", "--seconds", "--display", "--fps", "--max-edge", "--machine"],
    };
    let mut options = json!({});
    let (mut out, mut seconds, mut id, mut machine) = (None, None, None, None);
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        if !allowed.contains(word) {
            return Err(format!("unknown argument {word:?}\n{USAGE}"));
        }
        let value = *words.next().ok_or_else(|| format!("{word} needs a value"))?;
        match *word {
            "--out" => out = Some(value.to_owned()),
            "--id" => id = Some(value.to_owned()),
            "--machine" => machine = Some(value.to_owned()),
            "--seconds" => seconds = Some(number(word, value)?),
            "--max-seconds" => {
                options.set("max_seconds", json!(number(word, value)?));
            }
            "--display" => {
                options.set("display", json!(value));
            }
            "--fps" => {
                options.set("fps", json!(whole(word, value)?));
            }
            _ => {
                options.set("max_edge", json!(whole(word, value)?));
            }
        }
    }
    match verb {
        "start" => Ok(RecordRequest::Start { options, machine }),
        "stop" => {
            Ok(RecordRequest::Stop { out: out.ok_or("record stop needs --out FILE")?, id, machine })
        }
        _ => Ok(RecordRequest::Whole {
            out: out.ok_or("record needs --out FILE")?,
            seconds: seconds.ok_or("record needs --seconds N (or `record start`)")?,
            options,
            machine,
        }),
    }
}

fn fail(global: &GlobalArgs, code: &str, message: String) -> i32 {
    super::super::wire::print_local_error(
        &json!({"code": code, "message": message}),
        global.output,
        1,
    )
}

/// The recording `id`'s bytes into `out`: the engine's file copied when this
/// process can read it (the same machine and user), otherwise read through
/// the tool in pieces (another machine). Written beside `out` and renamed,
/// so `out` is never half a file.
fn save(
    global: &GlobalArgs,
    body: &Value,
    out: &str,
    machine: Option<&str>,
) -> Result<u64, (String, String)> {
    let partial = format!("{out}.partial-{}", std::process::id());
    let written = (|| -> Result<u64, (String, String)> {
        let write_failed = |e: std::io::Error| ("write_failed".to_owned(), format!("{out}: {e}"));
        if machine.is_none()
            && let Some(path) = body.get("path").and_then(Value::as_str)
            && let Ok(bytes) = std::fs::copy(path, &partial)
        {
            return Ok(bytes);
        }
        let id = body.get("recording_id").and_then(Value::as_str).unwrap_or_default();
        let mut file = std::fs::File::create(&partial).map_err(write_failed)?;
        let mut offset = 0u64;
        loop {
            let args = with_machine(
                json!({"action": "read", "recording_id": id, "offset": offset}),
                machine,
            );
            let piece = match caller(global).call("record", &args, &new_call_id()) {
                Outcome::Output(piece) if !piece.is_error => piece.body,
                Outcome::Output(piece) => {
                    let message = piece.body.get("error").and_then(Value::as_str);
                    return Err((
                        piece.code.unwrap_or_else(|| "read_failed".into()),
                        message.unwrap_or("the recording could not be read").to_owned(),
                    ));
                }
                Outcome::Off(reason) => return Err(("computer_use_off".into(), reason)),
                Outcome::Failed { code, message } => return Err((code, message)),
            };
            let data = piece.get("data_base64").and_then(Value::as_str).unwrap_or_default();
            let data = base64::engine::general_purpose::STANDARD
                .decode(data)
                .map_err(|e| ("bad_recording".to_owned(), e.to_string()))?;
            file.write_all(&data).map_err(write_failed)?;
            let next = piece.get("next_offset").and_then(Value::as_u64).unwrap_or(offset);
            if piece.get("eof") == Some(&json!(true)) || next <= offset {
                file.flush().map_err(write_failed)?;
                return Ok(next);
            }
            offset = next;
        }
    })();
    match written {
        Ok(bytes) => match std::fs::rename(&partial, out) {
            Ok(()) => Ok(bytes),
            Err(e) => {
                let _ = std::fs::remove_file(&partial);
                Err(("write_failed".into(), format!("{out}: {e}")))
            }
        },
        Err(e) => {
            let _ = std::fs::remove_file(&partial);
            Err(e)
        }
    }
}

/// Stops the recording and saves its file; the result names `out`.
fn stop_and_save(global: &GlobalArgs, out: &str, id: Option<&str>, machine: Option<&str>) -> i32 {
    let mut args = json!({"action": "stop"});
    if let Some(id) = id {
        args.set("recording_id", json!(id));
    }
    let args = with_machine(args, machine);
    match caller(global).call("record", &args, &new_call_id()) {
        Outcome::Output(done) if !done.is_error => {
            let mut body = done.body;
            let bytes = match save(global, &body, out, machine) {
                Ok(bytes) => bytes,
                Err((code, message)) => return fail(global, &code, message),
            };
            if body.get("bytes").and_then(Value::as_u64) != Some(bytes) {
                return fail(
                    global,
                    "bad_recording",
                    format!(
                        "{out}: {bytes} bytes saved, the recording has {}",
                        body.get("bytes").unwrap_or(&Value::Null)
                    ),
                );
            }
            // `path` is the worker's own copy; `out` is the caller's file.
            body.set("out", json!(out));
            super::super::wire::print_local_success(&body, global.output)
        }
        other => print(global, other),
    }
}

pub(super) fn run(global: &GlobalArgs, request: RecordRequest) -> i32 {
    match request {
        RecordRequest::Start { mut options, machine } => {
            options.set("action", json!("start"));
            let args = with_machine(options, machine.as_deref());
            print(global, caller(global).call("record", &args, &new_call_id()))
        }
        RecordRequest::Stop { out, id, machine } => {
            stop_and_save(global, &out, id.as_deref(), machine.as_deref())
        }
        RecordRequest::Whole { out, seconds, mut options, machine } => {
            // Fail before recording when the file could not be written.
            let probe = format!("{out}.partial-{}", std::process::id());
            if let Err(e) = std::fs::File::create(&probe) {
                return fail(global, "write_failed", format!("{out}: {e}"));
            }
            let _ = std::fs::remove_file(&probe);
            options.set("action", json!("start"));
            options.set("max_seconds", json!(seconds));
            let args = with_machine(options, machine.as_deref());
            let id = match caller(global).call("record", &args, &new_call_id()) {
                Outcome::Output(started) if !started.is_error => started
                    .body
                    .get("recording_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                other => return print(global, other),
            };
            // The recording ends itself at the cap; stop then returns the
            // finished file (and waits for it if a frame is still in flight).
            std::thread::sleep(Duration::from_secs_f64(seconds));
            stop_and_save(global, &out, Some(&id), machine.as_deref())
        }
    }
}
