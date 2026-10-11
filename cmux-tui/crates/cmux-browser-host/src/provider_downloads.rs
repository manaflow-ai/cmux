//! Downloads in the app's tabs (either engine), as the app reports them
//! (`download.started` / `download.finished` events): `download.path`
//! answers from the finished event, waiting for it until the call's
//! deadline, as headless Chromium's driver does (`cdp/downloads.rs`).

use crate::protocol::{DriverError, required_str, timeout_of};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::sync::{Condvar, Mutex, PoisonError};
use std::time::Instant;

/// Finished downloads kept for `download.path`; the oldest goes first.
const KEPT: usize = 64;

#[derive(Default)]
pub struct ProviderDownloads {
    finished: Mutex<VecDeque<(String, Result<String, String>)>>,
    changed: Condvar,
}

impl ProviderDownloads {
    /// Records the app's `download.finished` payload.
    pub fn record(&self, payload: &Value) {
        let Some(id) = payload.get("downloadId").and_then(Value::as_str) else { return };
        let outcome = match payload.get("path").and_then(Value::as_str) {
            Some(path) => Ok(path.to_owned()),
            None => Err(payload
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("the download failed")
                .to_owned()),
        };
        let mut finished = self.finished.lock().unwrap_or_else(PoisonError::into_inner);
        finished.retain(|(known, _)| known != id);
        finished.push_back((id.to_owned(), outcome));
        while finished.len() > KEPT {
            finished.pop_front();
        }
        drop(finished);
        self.changed.notify_all();
    }

    /// `download.path { downloadId }` -> `{ path }` once the download
    /// finished; its failure reason, or `timeout` at the call's deadline.
    pub fn path(&self, params: &Value) -> Result<Value, DriverError> {
        let id = required_str(params, "downloadId")?;
        let deadline = Instant::now() + timeout_of(params);
        let mut finished = self.finished.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            if let Some((_, outcome)) = finished.iter().find(|(known, _)| known == id) {
                return match outcome {
                    Ok(path) => Ok(json!({"path": path})),
                    Err(reason) => Err(DriverError::invalid(format!(
                        "download.path: download {id} failed: {reason}"
                    ))),
                };
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(DriverError::timeout(format!(
                    "download.path: download {id} did not finish in time"
                )));
            }
            finished = self
                .changed
                .wait_timeout(finished, deadline - now)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }
}
