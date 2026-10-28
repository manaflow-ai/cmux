//! The TUI's background requests to the daemon. Each is scoped to one action: a panic in
//! it ends only that action, which says so on the status line (`AppMsg::Error`); the TUI
//! goes on (`crate::supervised::spawn_request`).

use std::future::Future;

use tokio::sync::mpsc;

use super::{App, AppMsg};

/// Starts `work`, one background request whose results reach the app through `tx`.
pub(super) fn spawn(
    tx: mpsc::UnboundedSender<AppMsg>,
    work: impl Future<Output = ()> + Send + 'static,
) {
    crate::supervised::spawn_request(work, async move {
        let _ = tx.send(AppMsg::Error("the request failed".into()));
    });
}

impl App {
    /// Starts `work`, one background request of this app.
    pub(super) fn background(&self, work: impl Future<Output = ()> + Send + 'static) {
        spawn(self.tx.clone(), work);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_request_that_panics_says_so_on_the_status_line() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        spawn(tx.clone(), async {
            panic!("injected");
        });
        let msg = tokio::time::timeout(std::time::Duration::from_secs(5), rx.recv()).await;
        assert!(matches!(msg, Ok(Some(AppMsg::Error(text))) if text == "the request failed"));
    }
}
