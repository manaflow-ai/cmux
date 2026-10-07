//! Reload the harness catalog when a manifest in `~/.config/cmux/harnesses/`
//! changes, so a new or edited harness shows up without restarting the
//! daemon. File-system events, no polling; open chats keep running on the
//! profile they started with.

use std::sync::Arc;
use std::time::Duration;

use notify::{RecursiveMode, Watcher};

use crate::hub::Hub;

/// A save arrives as several events (write, rename, chmod); reload once
/// they have settled.
const SETTLE: Duration = Duration::from_millis(300);

pub async fn run(hub: Arc<Hub>) {
    let Some(root) = crate::config::manifest::user_dir() else {
        return;
    };
    // The folder exists from the first run so users (and their agents) find
    // where harnesses go, and so there is something to watch.
    if let Err(e) = std::fs::create_dir_all(&root) {
        tracing::warn!(dir = %root.display(), "harness folder unavailable: {e}");
        return;
    }
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<()>();
    let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        if event.is_ok_and(|e| !e.kind.is_access()) {
            let _ = tx.send(());
        }
    });
    let mut watcher = match watcher {
        Ok(w) => w,
        Err(e) => {
            tracing::warn!(dir = %root.display(), "harness folder not watched: {e}");
            return;
        }
    };
    if let Err(e) = watcher.watch(&root, RecursiveMode::Recursive) {
        tracing::warn!(dir = %root.display(), "harness folder not watched: {e}");
        return;
    }
    while rx.recv().await.is_some() {
        tokio::time::sleep(SETTLE).await;
        while rx.try_recv().is_ok() {}
        match hub.reload_catalog_with(false).await {
            Ok(_) => {
                tracing::info!(dir = %root.display(), "harness manifests changed; catalog reloaded")
            }
            Err(e) => tracing::warn!(
                dir = %root.display(),
                "harness manifests changed; reload failed: {}",
                e.message
            ),
        }
    }
    drop(watcher);
}
