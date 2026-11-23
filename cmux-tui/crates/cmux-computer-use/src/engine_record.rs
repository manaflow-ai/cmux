//! The `record` tool: a display recorded to an MP4 ([`crate::record`]).
//!
//! `record` with `seconds` records that long and returns when the file is
//! whole (one call, for a script that is one process). `action: "start"`
//! returns at once with a `recording_id` and the recording runs on in the
//! engine, bounded by `max_seconds`; `action: "stop"` ends it and returns
//! the file; `action: "read"` returns a finished file's bytes in pieces to
//! a caller that cannot read the engine's disk (another machine).
//!
//! Policy: a recording is a display screenshot many times over, so starting
//! one passes the same check (the mode, the whole-screen approval, the
//! locked-screen refusal in `Engine::dispatch`), and every frame goes
//! through the display screenshot's rules for denied apps.

use std::io::{Read as _, Seek as _, SeekFrom};
use std::time::Duration;

use base64::Engine as _;
use serde_json::{Value, json};

use super::{CallContext, Engine, ToolOutput, args_str};
use crate::policy::{Access, PolicyConfig, TargetApp};
use crate::record::{self, Options, RecordError, Source, Summary};

fn failed(e: &RecordError) -> ToolOutput {
    ToolOutput::error(&e.code, e.message.clone())
}

fn invalid(message: impl Into<String>) -> ToolOutput {
    ToolOutput::error("invalid_arguments", message)
}

/// A number of seconds in (0, [`record::MAX_SECONDS`]].
fn seconds(args: &Value, key: &str) -> Result<Option<f64>, ToolOutput> {
    let Some(value) = args.get(key).filter(|v| !v.is_null()) else {
        return Ok(None);
    };
    match value.as_f64() {
        Some(s) if s > 0.0 && s <= record::MAX_SECONDS => Ok(Some(s)),
        _ => Err(invalid(format!(
            "{key} must be a number of seconds above 0 and at most {}",
            record::MAX_SECONDS
        ))),
    }
}

fn whole(args: &Value, key: &str, min: u32, max: u32, default: u32) -> Result<u32, ToolOutput> {
    let Some(value) = args.get(key).filter(|v| !v.is_null()) else {
        return Ok(default);
    };
    match value.as_u64() {
        Some(n) if n >= u64::from(min) && n <= u64::from(max) => Ok(n as u32),
        _ => Err(invalid(format!("{key} must be a whole number from {min} to {max}"))),
    }
}

fn summary_json(id: &str, s: &Summary) -> Value {
    let mut body = json!({
        "recording_id": id,
        "recording": false,
        "path": s.path.to_string_lossy(),
        "duration_ms": s.duration_ms,
        "frames": s.frames,
        "keyframes": s.keyframes,
        "bytes": s.bytes,
        "width": s.width,
        "height": s.height,
        "fps": s.fps,
        "codec": "h264",
        "container": "mp4",
        "encoder": s.encoder,
        "display": s.display,
        "ended": s.ended,
        "redacted_windows": s.redacted_windows,
        "left_out_apps": s.left_out_apps,
    });
    if let Some(detail) = &s.detail {
        body["detail"] = json!(detail);
    }
    body
}

impl Engine {
    pub(super) fn record(
        &self,
        config: &PolicyConfig,
        ctx: &CallContext,
        args: &Value,
    ) -> Result<(ToolOutput, Option<TargetApp>), ToolOutput> {
        let action = args_str(args, "action").unwrap_or("record");
        if !matches!(action, "record" | "start" | "stop" | "read") {
            return Err(invalid(format!(
                "unknown action {action:?}: record (the default), start, stop or read"
            )));
        }
        // The same check as a display screenshot, for every action: a stopped
        // recording's file and its bytes are the screen too.
        self.authorize(config, ctx, Access::Observe, None, false)?;
        match action {
            "stop" => {
                let (id, summary) = self
                    .recorder
                    .stop(&ctx.session, args_str(args, "recording_id"))
                    .map_err(|e| failed(&e))?;
                Ok((ToolOutput::ok(summary_json(&id, &summary)), None))
            }
            "read" => self.record_read(ctx, args),
            _ => {
                if args_str(args, "window_id").is_some() {
                    return Err(invalid(
                        "record takes a display, not a window: omit window_id (pass display for \
                         one that is not the main display)",
                    ));
                }
                let length = if action == "record" {
                    seconds(args, "seconds")?.ok_or_else(|| {
                        invalid(
                            "seconds is required: how long to record. To record until you say \
                             stop, pass action \"start\" and later action \"stop\".",
                        )
                    })?
                } else {
                    seconds(args, "max_seconds")?.unwrap_or(record::DEFAULT_MAX_SECONDS)
                };
                let options = Options {
                    display: args_str(args, "display").map(str::to_string),
                    fps: whole(args, "fps", 1, record::MAX_FPS, record::DEFAULT_FPS)?,
                    limit: Duration::from_secs_f64(length),
                    max_edge: whole(
                        args,
                        "max_edge",
                        record::MIN_MAX_EDGE,
                        record::MAX_MAX_EDGE,
                        record::DEFAULT_MAX_EDGE,
                    )?,
                };
                let source = Source {
                    desktop: self.desktop.clone(),
                    config: self.config.clone(),
                    sessions: self.sessions.clone(),
                    stops: self.stops.clone(),
                };
                let id = self
                    .recorder
                    .start(source, &ctx.session, options.clone())
                    .map_err(|e| failed(&e))?;
                if action == "start" {
                    return Ok((
                        ToolOutput::ok(json!({
                            "recording_id": id,
                            "recording": true,
                            "max_seconds": length,
                            "fps": options.fps,
                            "display": options.display.as_deref().unwrap_or("main"),
                            "next": "call record with action \"stop\" for the file; it ends by itself at max_seconds",
                        })),
                        None,
                    ));
                }
                let summary = self.recorder.wait(&id).map_err(|e| failed(&e))?;
                Ok((ToolOutput::ok(summary_json(&id, &summary)), None))
            }
        }
    }

    /// One piece of a finished recording's file, for a caller on another
    /// machine. The file is found by the recording's id among this session's
    /// own: a caller never names a path.
    fn record_read(
        &self,
        ctx: &CallContext,
        args: &Value,
    ) -> Result<(ToolOutput, Option<TargetApp>), ToolOutput> {
        let id =
            args_str(args, "recording_id").ok_or_else(|| invalid("read needs recording_id"))?;
        let offset = args.get("offset").and_then(Value::as_u64).unwrap_or(0);
        let path = self.recorder.file(&ctx.session, id).map_err(|e| failed(&e))?;
        let read = || -> std::io::Result<(u64, Vec<u8>)> {
            let mut file = std::fs::File::open(&path)?;
            let total = file.metadata()?.len();
            file.seek(SeekFrom::Start(offset.min(total)))?;
            let mut chunk = Vec::with_capacity(record::READ_CHUNK);
            file.take(record::READ_CHUNK as u64).read_to_end(&mut chunk)?;
            Ok((total, chunk))
        };
        let (total, chunk) = read().map_err(|e| {
            ToolOutput::error("recording_failed", format!("the recording's file: {e}"))
        })?;
        let next = offset.min(total) + chunk.len() as u64;
        Ok((
            ToolOutput::ok(json!({
                "recording_id": id,
                "offset": offset.min(total),
                "next_offset": next,
                "bytes": total,
                "eof": next >= total,
                "data_base64": base64::engine::general_purpose::STANDARD.encode(&chunk),
            })),
            None,
        ))
    }
}
