//! Part of `Hub`; see `hub/mod.rs`. What the row tables (`rows/serve.rs`) read from the hub.

use super::*;

impl crate::rows::RowsSource for Hub {
    fn rows_cache(&self) -> &crate::rows::RowsCache {
        &self.rows
    }

    fn scan_log(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_events(id, after, visit)
    }
}
