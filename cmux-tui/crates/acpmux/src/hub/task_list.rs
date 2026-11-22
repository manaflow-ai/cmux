//! Part of `Hub`; see `hub/mod.rs`. A chat's task list (`crate::task_list`): set by the harness's
//! plan as it streams (`permissions.rs` `on_update`) or by `_acpmux/task_list/set`
//! (`server/task_list.rs`), saved with the meta and announced as a `task_list` record, which
//! watchers hear as `_acpmux/session_changed` (`server/change_kind.rs`): the sidebar row and every
//! open chat redraw from the summary's `taskList`.

use super::*;
use crate::task_list::{self, TaskListSource};

/// The record a change of the list is logged as.
pub(crate) const RECORD_KIND: &str = "task_list";

impl Hub {
    /// Logs and saves `session`'s task list after it changed.
    pub(super) fn task_list_changed(&self, session: &Session) {
        let list = session
            .read_meta(|m| m.task_list.as_ref().map(task_list::TaskList::summary))
            .map_or(Value::Null, |s| serde_json::to_value(s).unwrap_or(Value::Null));
        self.append(session, "mux", RECORD_KIND, json!({"taskList": list}));
        self.save_meta(session);
    }

    /// Sets `session`'s task list to `items`, kept by `source`; an empty list clears it. Answers
    /// the list's summary, null once cleared, after the meta is on disk.
    pub(crate) fn task_list_set(
        &self,
        session: &Session,
        source: TaskListSource,
        items: Vec<task_list::TaskItem>,
    ) -> Result<Value, RpcError> {
        let changed = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            match task_list::after_set(m.task_list.as_ref(), source, items, now_ms()) {
                Some(list) => {
                    m.task_list = list;
                    true
                }
                None => false,
            }
        };
        if changed {
            let list = self.task_list_get(session);
            self.append(session, "mux", RECORD_KIND, json!({"taskList": list}));
            self.save_meta_answered(session)?;
        }
        Ok(self.task_list_get(session))
    }

    /// `session`'s task list's summary, or null.
    pub(crate) fn task_list_get(&self, session: &Session) -> Value {
        session
            .read_meta(|m| m.task_list.as_ref().map(task_list::TaskList::summary))
            .map_or(Value::Null, |s| serde_json::to_value(s).unwrap_or(Value::Null))
    }
}
