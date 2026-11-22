//! The structured cause of each terminal's last host loss (cx-0tgl LA), for
//! the dead tab's `end.cause`. Live losses are recorded as they happen; a
//! restarted owner reads the causes of earlier losses back from
//! `terminal-losses.jsonl` once, on the first dead tab that needs one.

use std::collections::HashMap;
#[cfg(unix)]
use std::path::Path;

use serde_json::Value;

#[derive(Debug, Default)]
pub(crate) struct LossCauses {
    /// By public terminal id.
    by_public: HashMap<String, Value>,
    /// By host terminal id, from the loss log; loaded on first use.
    #[cfg_attr(not(unix), allow(dead_code))]
    logged: Option<HashMap<String, Value>>,
}

impl LossCauses {
    pub(crate) fn record(&mut self, public_id: &str, cause: Value) {
        self.by_public.insert(public_id.to_string(), cause);
    }

    pub(crate) fn forget(&mut self, public_id: &str) {
        self.by_public.remove(public_id);
    }

    pub(crate) fn snapshot(&self) -> HashMap<String, Value> {
        self.by_public.clone()
    }

    /// Give the dead tab of `terminal_id` (public id `public_id`) the cause
    /// its loss logged before this owner started, unless it has one.
    #[cfg(unix)]
    pub(crate) fn restore(&mut self, root: Option<&Path>, terminal_id: &str, public_id: &str) {
        if self.by_public.contains_key(public_id) {
            return;
        }
        let logged = self.logged.get_or_insert_with(|| {
            root.map(crate::terminal_loss_log::logged_summaries).unwrap_or_default()
        });
        if let Some(cause) = logged.get(terminal_id) {
            self.by_public.insert(public_id.to_string(), cause.clone());
        }
    }
}
