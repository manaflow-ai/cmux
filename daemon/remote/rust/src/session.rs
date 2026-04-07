use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::pane::PaneHandle;

#[derive(Debug, Clone, serde::Serialize)]
pub struct AttachmentSnapshot {
    pub attachment_id: String,
    pub cols: u16,
    pub rows: u16,
    pub updated_at: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct SessionSnapshot {
    pub session_id: String,
    pub attachments: Vec<AttachmentSnapshot>,
    pub effective_cols: u16,
    pub effective_rows: u16,
    pub last_known_cols: u16,
    pub last_known_rows: u16,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct SessionListEntry {
    pub session_id: String,
    pub attachment_count: usize,
    pub effective_cols: u16,
    pub effective_rows: u16,
}

#[derive(Debug, Clone)]
pub struct AttachmentState {
    pub cols: u16,
    pub rows: u16,
    pub updated_at_ms: u64,
}

#[derive(Debug)]
pub struct SessionMeta {
    pub attachments: BTreeMap<String, AttachmentState>,
    pub effective_cols: u16,
    pub effective_rows: u16,
    pub last_known_cols: u16,
    pub last_known_rows: u16,
}

#[derive(Debug)]
pub struct Window {
    pub id: String,
    pub name: String,
    pub panes: Vec<PaneSlot>,
    pub active_pane: usize,
    pub last_pane: Option<usize>,
}

#[derive(Debug)]
pub struct PaneSlot {
    pub pane_id: String,
    pub command: String,
    pub handle: Arc<PaneHandle>,
}

#[derive(Debug)]
pub struct SessionInner {
    pub windows: Vec<Window>,
    pub active_window: usize,
    pub last_window: Option<usize>,
}

#[derive(Debug)]
pub struct Session {
    pub id: String,
    pub meta: Mutex<SessionMeta>,
    pub inner: Mutex<SessionInner>,
}

#[derive(Debug)]
pub enum SessionError {
    NotFound,
    AttachmentNotFound,
    InvalidSize,
}

impl Session {
    pub fn new(id: String) -> Self {
        Self {
            id,
            meta: Mutex::new(SessionMeta {
                attachments: BTreeMap::new(),
                effective_cols: 0,
                effective_rows: 0,
                last_known_cols: 0,
                last_known_rows: 0,
            }),
            inner: Mutex::new(SessionInner {
                windows: Vec::new(),
                active_window: 0,
                last_window: None,
            }),
        }
    }

    pub fn attach(&self, attachment_id: String, cols: u16, rows: u16) -> Result<(), SessionError> {
        let (cols, rows) = normalize_size(cols, rows);
        if cols == 0 || rows == 0 {
            return Err(SessionError::InvalidSize);
        }
        let mut meta = self.meta.lock().unwrap();
        meta.attachments.insert(
            attachment_id,
            AttachmentState {
                cols,
                rows,
                updated_at_ms: now_ms(),
            },
        );
        recompute(&mut meta);
        Ok(())
    }

    pub fn resize_attachment(
        &self,
        attachment_id: &str,
        cols: u16,
        rows: u16,
    ) -> Result<(), SessionError> {
        let (cols, rows) = normalize_size(cols, rows);
        if cols == 0 || rows == 0 {
            return Err(SessionError::InvalidSize);
        }
        let mut meta = self.meta.lock().unwrap();
        let attachment = meta
            .attachments
            .get_mut(attachment_id)
            .ok_or(SessionError::AttachmentNotFound)?;
        attachment.cols = cols;
        attachment.rows = rows;
        attachment.updated_at_ms = now_ms();
        recompute(&mut meta);
        Ok(())
    }

    pub fn detach(&self, attachment_id: &str) -> Result<(), SessionError> {
        let mut meta = self.meta.lock().unwrap();
        if meta.attachments.remove(attachment_id).is_none() {
            return Err(SessionError::AttachmentNotFound);
        }
        recompute(&mut meta);
        Ok(())
    }

    pub fn snapshot(&self) -> SessionSnapshot {
        let meta = self.meta.lock().unwrap();
        SessionSnapshot {
            session_id: self.id.clone(),
            attachments: meta
                .attachments
                .iter()
                .map(|(attachment_id, attachment)| AttachmentSnapshot {
                    attachment_id: attachment_id.clone(),
                    cols: attachment.cols,
                    rows: attachment.rows,
                    updated_at: Some(format_iso8601(attachment.updated_at_ms)),
                })
                .collect(),
            effective_cols: meta.effective_cols,
            effective_rows: meta.effective_rows,
            last_known_cols: meta.last_known_cols,
            last_known_rows: meta.last_known_rows,
        }
    }

    pub fn list_entry(&self) -> SessionListEntry {
        let meta = self.meta.lock().unwrap();
        SessionListEntry {
            session_id: self.id.clone(),
            attachment_count: meta.attachments.len(),
            effective_cols: meta.effective_cols,
            effective_rows: meta.effective_rows,
        }
    }

    pub fn effective_size(&self) -> (u16, u16) {
        let meta = self.meta.lock().unwrap();
        (meta.effective_cols, meta.effective_rows)
    }
}

pub fn normalize_size(cols: u16, rows: u16) -> (u16, u16) {
    let normalized_cols = if cols == 0 { 0 } else { cols.max(2) };
    let normalized_rows = if rows == 0 { 0 } else { rows.max(1) };
    (normalized_cols, normalized_rows)
}

fn recompute(meta: &mut SessionMeta) {
    if meta.attachments.is_empty() {
        meta.effective_cols = meta.last_known_cols;
        meta.effective_rows = meta.last_known_rows;
        return;
    }

    let mut min_cols = 0;
    let mut min_rows = 0;
    for attachment in meta.attachments.values() {
        if min_cols == 0 || attachment.cols < min_cols {
            min_cols = attachment.cols;
        }
        if min_rows == 0 || attachment.rows < min_rows {
            min_rows = attachment.rows;
        }
    }
    meta.effective_cols = min_cols;
    meta.effective_rows = min_rows;
    meta.last_known_cols = min_cols;
    meta.last_known_rows = min_rows;
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis() as u64)
        .unwrap_or_default()
}

fn format_iso8601(timestamp_ms: u64) -> String {
    let secs = (timestamp_ms / 1000) as libc::time_t;
    let millis = timestamp_ms % 1000;
    let mut tm = unsafe { std::mem::zeroed::<libc::tm>() };
    let tm_ptr = unsafe { libc::gmtime_r(&secs, &mut tm) };
    if tm_ptr.is_null() {
        return format!("{}", timestamp_ms / 1000);
    }
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec,
        millis
    )
}

#[cfg(test)]
mod tests {
    use super::format_iso8601;

    #[test]
    fn format_iso8601_emits_rfc3339_timestamp() {
        assert_eq!(
            format_iso8601(1_704_067_445_678),
            "2024-01-01T00:04:05.678Z"
        );
    }
}
