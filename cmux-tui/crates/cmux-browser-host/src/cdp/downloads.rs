//! Downloads on headless Chromium (driver-protocol.md "Files, dialogs,
//! popups, downloads"): `Browser.setDownloadBehavior` saves every download
//! under the browser's private directory with its guid as the file name, and
//! the browser's download events become `download.started` /
//! `download.finished`. `download.path` waits for the file.

use super::driver::{CdpDriver, INTERNAL_TIMEOUT, Inner};
use super::state::{Applied, State};
use crate::protocol::{DriverError, DriverEvent, required_str, timeout_of};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::PoisonError;
use std::time::Instant;

/// Finished downloads kept for `download.path`; older finished ones are
/// dropped when a new download starts (no timer). Downloads in progress are
/// always kept.
const KEPT_FINISHED: usize = 64;

#[derive(Debug)]
pub struct Download {
    target_id: String,
    /// `Some(Ok(path))` once completed, `Some(Err(reason))` once cancelled.
    outcome: Option<Result<PathBuf, String>>,
}

#[derive(Debug, Default)]
pub struct Downloads {
    dir: Option<PathBuf>,
    /// By guid, oldest first.
    entries: Vec<(String, Download)>,
}

impl Downloads {
    fn get(&self, guid: &str) -> Option<&Download> {
        self.entries.iter().find(|(id, _)| id == guid).map(|(_, d)| d)
    }

    fn sweep(&mut self) {
        let mut finished = self.entries.iter().filter(|(_, d)| d.outcome.is_some()).count();
        self.entries.retain(|(_, d)| {
            if d.outcome.is_some() && finished > KEPT_FINISHED {
                finished -= 1;
                return false;
            }
            true
        });
    }
}

fn event(name: &str, target_id: &str, payload: Value) -> DriverEvent {
    let mut payload = payload;
    payload["targetId"] = json!(target_id);
    DriverEvent { name: name.to_owned(), payload }
}

impl State {
    /// The tab a frame id belongs to.
    fn tab_of_frame(&self, frame_id: &str) -> Option<String> {
        if self.tabs.contains_key(frame_id) {
            return Some(frame_id.to_owned());
        }
        self.tabs
            .iter()
            .find(|(_, tab)| {
                tab.main_frame.as_deref() == Some(frame_id)
                    || tab.frame_urls.contains_key(frame_id)
                    || tab.frame_sessions.contains_key(frame_id)
            })
            .map(|(id, _)| id.clone())
    }

    /// `Browser.downloadWillBegin` / `Browser.downloadProgress`.
    pub(super) fn download_event(&mut self, method: &str, params: &Value, applied: &mut Applied) {
        let Some(guid) = params.get("guid").and_then(Value::as_str) else {
            return;
        };
        if method == "Browser.downloadWillBegin" {
            let frame = params.get("frameId").and_then(Value::as_str).unwrap_or("");
            let Some(target_id) = self.tab_of_frame(frame) else {
                return;
            };
            self.downloads.sweep();
            self.downloads
                .entries
                .push((guid.to_owned(), Download { target_id: target_id.clone(), outcome: None }));
            applied.events.push(event(
                "download.started",
                &target_id,
                json!({
                    "downloadId": guid,
                    "url": params.get("url").cloned().unwrap_or(json!("")),
                    "suggestedFilename": params.get("suggestedFilename").cloned().unwrap_or(json!("")),
                }),
            ));
            return;
        }
        let dir = self.downloads.dir.clone();
        let Some((_, download)) = self.downloads.entries.iter_mut().find(|(id, _)| id == guid)
        else {
            return;
        };
        if download.outcome.is_some() {
            return;
        }
        let outcome = match params.get("state").and_then(Value::as_str) {
            Some("completed") => match dir {
                Some(dir) => Ok(dir.join(guid)),
                None => Err("the download has no directory".to_owned()),
            },
            Some("canceled") => Err("canceled".to_owned()),
            _ => return,
        };
        let payload = match &outcome {
            Ok(path) => json!({"downloadId": guid, "path": path.display().to_string()}),
            Err(reason) => json!({"downloadId": guid, "error": reason}),
        };
        download.outcome = Some(outcome);
        applied.events.push(event("download.finished", &download.target_id, payload));
    }
}

impl Inner {
    /// `download.path { downloadId }` -> `{ path }` once the download
    /// completed (waits for it until the call's deadline).
    pub(super) fn download_path(&self, params: &Value) -> Result<Value, DriverError> {
        let guid = required_str(params, "downloadId")?;
        let deadline = Instant::now() + timeout_of(params);
        let mut state = self.lock();
        loop {
            match state.downloads.get(guid) {
                None => return Err(DriverError::not_found(format!("No download {guid}"))),
                Some(Download { outcome: Some(Ok(path)), .. }) => {
                    return Ok(json!({"path": path.display().to_string()}));
                }
                Some(Download { outcome: Some(Err(reason)), .. }) => {
                    return Err(DriverError::invalid(format!("download.path: {reason}")));
                }
                Some(Download { outcome: None, .. }) => {}
            }
            if let Some(reason) = self.conn.closed_reason() {
                return Err(DriverError::closed(reason));
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(DriverError::timeout("Timed out waiting for the download"));
            }
            state = self
                .changed
                .wait_timeout(state, deadline - now)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }
}

impl Inner {
    /// `download.cancel { downloadId }`: stops a download (the host's answer
    /// to one no session takes, D2).
    pub(super) fn download_cancel(&self, params: &Value) -> Result<Value, DriverError> {
        let guid = required_str(params, "downloadId")?;
        self.conn.call(None, "Browser.cancelDownload", json!({"guid": guid}), INTERNAL_TIMEOUT)?;
        Ok(Value::Null)
    }
}

impl CdpDriver {
    /// Saves the browser's downloads in `dir` and reports them as
    /// `download.started` / `download.finished` (headless Chromium only).
    pub fn save_downloads_in(&self, dir: &Path) -> Result<(), DriverError> {
        self.inner.lock().downloads.dir = Some(dir.to_path_buf());
        self.inner.conn.call(
            None,
            "Browser.setDownloadBehavior",
            json!({"behavior": "allowAndName", "downloadPath": dir.display().to_string(), "eventsEnabled": true}),
            INTERNAL_TIMEOUT,
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn begin(state: &mut State, guid: &str) {
        let mut applied = Applied::default();
        state.download_event(
            "Browser.downloadWillBegin",
            &json!({"guid": guid, "frameId": "T", "url": "u", "suggestedFilename": "f"}),
            &mut applied,
        );
    }

    #[test]
    fn finished_downloads_are_bounded_and_running_ones_kept() {
        let mut state = State::default();
        state.tabs.insert(
            "T".into(),
            super::super::state::TabState::new("s".into(), "u".into(), String::new(), None),
        );
        state.downloads.dir = Some(PathBuf::from("/d"));
        begin(&mut state, "running");
        for i in 0..KEPT_FINISHED + 10 {
            let guid = format!("g{i}");
            begin(&mut state, &guid);
            let mut applied = Applied::default();
            state.download_event(
                "Browser.downloadProgress",
                &json!({"guid": guid, "state": "completed"}),
                &mut applied,
            );
            assert_eq!(applied.events[0].payload["path"], format!("/d/{guid}"));
        }
        begin(&mut state, "last");
        assert!(state.downloads.entries.len() <= KEPT_FINISHED + 2);
        assert!(state.downloads.get("running").is_some());
        assert!(state.downloads.get("g0").is_none());
    }
}
