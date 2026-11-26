//! `FrameStripKeyRepeat`: the frame strip's key repeat schedule.

use super::run;
use crate::ops::OpResult;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `FrameStripKeyRepeat.interval`, in milliseconds: at least 1, 40 when unset.
pub fn key_repeat_interval(interval_ms: Option<f64>) -> i64 {
    (interval_ms.unwrap_or(40.0).trunc() as i64).max(1)
}

/// `FrameStripKeyRepeat.delay(beforeKey:elapsed:)`, in milliseconds.
pub fn key_repeat_delay(interval_ms: i64, index: i64, elapsed_ms: f64) -> f64 {
    ((interval_ms * index) as f64 - elapsed_ms).max(0.0)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyRepeatRequest {
    #[serde(default)]
    interval_ms: Option<f64>,
    #[serde(default)]
    index: i64,
    #[serde(default)]
    elapsed_ms: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct KeyRepeatReply {
    interval_ms: i64,
    delay_ms: f64,
}

/// `window.frameStripKeyRepeat` `{intervalMs?, index, elapsedMs}` → `{intervalMs, delayMs}`.
pub(super) fn op_key_repeat(request: &Value) -> OpResult {
    run(request, |r: KeyRepeatRequest| {
        let interval_ms = key_repeat_interval(r.interval_ms);
        KeyRepeatReply {
            interval_ms,
            delay_ms: key_repeat_delay(interval_ms, r.index, r.elapsed_ms),
        }
    })
}
