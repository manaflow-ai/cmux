use std::collections::VecDeque;
use std::sync::Arc;

use chrono::Utc;
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::models::{NotificationLevel, NotificationLogEntry};

const MAX_NOTIFICATION_LOG: usize = 512;

fn normalize_opt(value: Option<String>) -> Option<String> {
    value
        .map(|raw| raw.trim().to_string())
        .filter(|item| !item.is_empty())
}

#[derive(Clone, Default)]
pub struct NotificationStore {
    inner: Arc<RwLock<VecDeque<NotificationLogEntry>>>,
}

impl NotificationStore {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(RwLock::new(VecDeque::new())),
        }
    }

    pub async fn record(
        &self,
        message: String,
        level: NotificationLevel,
        sandbox_id: Option<String>,
        tab_id: Option<String>,
        pane_id: Option<String>,
    ) -> NotificationLogEntry {
        let entry = NotificationLogEntry {
            id: Uuid::new_v4(),
            message,
            level,
            sandbox_id: normalize_opt(sandbox_id),
            tab_id: normalize_opt(tab_id),
            pane_id: normalize_opt(pane_id),
            received_at: Utc::now(),
        };

        let mut guard = self.inner.write().await;
        guard.push_front(entry.clone());
        if guard.len() > MAX_NOTIFICATION_LOG {
            guard.pop_back();
        }

        entry
    }

    pub async fn list(&self) -> Vec<NotificationLogEntry> {
        let guard = self.inner.read().await;
        guard.iter().cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn records_and_limits_notifications() {
        let store = NotificationStore::new();

        for idx in 0..(MAX_NOTIFICATION_LOG + 5) {
            let _ = store
                .record(
                    format!("message-{idx}"),
                    NotificationLevel::Info,
                    Some(format!("sandbox-{idx}")),
                    Some("  ".to_string()),
                    None,
                )
                .await;
        }

        let items = store.list().await;
        assert_eq!(items.len(), MAX_NOTIFICATION_LOG);
        assert_eq!(
            items.first().map(|item| &item.message),
            Some(&"message-516".to_string())
        );
        assert_eq!(
            items.last().map(|item| &item.message),
            Some(&format!("message-{}", 5))
        );
        assert_eq!(items.first().and_then(|item| item.tab_id.clone()), None);
    }
}
