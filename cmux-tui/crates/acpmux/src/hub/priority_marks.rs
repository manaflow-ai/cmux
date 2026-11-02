//! Part of `Hub`; see `hub/mod.rs`. The person's marks on the Priority view's chats (pinned,
//! read, snoozed, archived, dragged to a place, the view folded), owned by the daemon: one copy
//! for every window of every connection, kept in `<home>/priority-marks.json` (written whole, off
//! the executor; read once, at the first use: a small file). The Mac app kept them in its
//! UserDefaults (`AgentPriorityMarks.swift`); a client hands that copy over once (`importMarks`
//! in `_acpmux/priority_window`), and acpmux takes it only while it has none of its own: any
//! mark made first (another client, a window opened without `importMarks`) makes them the
//! daemon's, so a client sends `importMarks` with its first open. A memory store keeps the
//! marks in memory only.
//!
//! Every change bumps a generation that every connection's window task watches, so a mark made
//! through one window shows in every window at once.

use std::path::{Path, PathBuf};
use std::sync::Mutex as StdMutex;

use serde::Deserialize;
use serde_json::Value;
use tokio::sync::watch;

use super::priority::{Marks, Snooze};

/// The file the marks are kept in, under the daemon's home.
pub(crate) const FILE: &str = "priority-marks.json";

pub(crate) struct MarksStore {
    path: Option<PathBuf>,
    /// None until the first read: the file is read on first use, not at daemon start.
    marks: StdMutex<Option<Loaded>>,
    changed: watch::Sender<u64>,
    /// One write of the file at a time, the newest last.
    writing: tokio::sync::Mutex<()>,
}

#[derive(Clone)]
struct Loaded {
    marks: Marks,
    /// The daemon has marks of its own (its file, or an import): an import is refused.
    owned: bool,
}

fn lock<T>(mutex: &StdMutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// The marks in `path`; none when it is absent or unreadable (a broken file is set aside, so the
/// next write does not lose it silently).
fn read(path: &Path) -> Option<Marks> {
    let bytes = std::fs::read(path).ok()?;
    match serde_json::from_slice(&bytes) {
        Ok(marks) => Some(marks),
        Err(error) => {
            tracing::warn!(path = %path.display(), %error, "priority marks unreadable; set aside");
            let _ = std::fs::rename(path, path.with_extension("json.unreadable"));
            None
        }
    }
}

impl MarksStore {
    pub(crate) fn open(path: Option<PathBuf>) -> Self {
        Self {
            path,
            marks: StdMutex::new(None),
            changed: watch::channel(0).0,
            writing: Default::default(),
        }
    }

    fn loaded<'a>(&self, guard: &'a mut Option<Loaded>) -> &'a mut Loaded {
        guard.get_or_insert_with(|| {
            let file = self.path.as_deref().and_then(read);
            Loaded { owned: file.is_some(), marks: file.unwrap_or_default() }
        })
    }

    /// The marks now.
    pub(crate) fn get(&self) -> Marks {
        let mut guard = lock(&self.marks);
        self.loaded(&mut guard).marks.clone()
    }

    /// Watches every change of the marks.
    pub(crate) fn subscribe(&self) -> watch::Receiver<u64> {
        self.changed.subscribe()
    }

    /// Takes `imported` (the client's saved marks) when the daemon has none of its own yet.
    /// True when it took them.
    pub(crate) async fn import(&self, imported: Marks) -> bool {
        let taken = {
            let mut guard = lock(&self.marks);
            let loaded = self.loaded(&mut guard);
            if loaded.owned {
                return false;
            }
            *loaded = Loaded { marks: imported, owned: true };
            loaded.marks.clone()
        };
        self.saved(taken).await;
        true
    }

    /// Changes the marks with `change` (which may refuse); every window hears of it.
    pub(crate) async fn change<T>(
        &self,
        change: impl FnOnce(&mut Marks) -> Result<T, String>,
    ) -> Result<(T, Marks), String> {
        let (out, marks) = {
            let mut guard = lock(&self.marks);
            let loaded = self.loaded(&mut guard);
            let mut next = loaded.marks.clone();
            let out = change(&mut next)?;
            if next == loaded.marks {
                return Ok((out, next));
            }
            *loaded = Loaded { marks: next.clone(), owned: true };
            (out, next)
        };
        self.saved(marks.clone()).await;
        Ok((out, marks))
    }

    /// Tells the windows, then writes the file with the newest marks.
    async fn saved(&self, marks: Marks) {
        self.changed.send_modify(|generation| *generation = generation.wrapping_add(1));
        let Some(path) = self.path.clone() else { return };
        let _one = self.writing.lock().await;
        // The newest marks, which a later change may have replaced meanwhile.
        let newest = lock(&self.marks).as_ref().map_or(marks, |loaded| loaded.marks.clone());
        let written = tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let value = serde_json::to_value(&newest)?;
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            super::atomic_json::write_json_atomic(&path, &value)
        })
        .await;
        match written {
            Ok(Ok(())) => {}
            Ok(Err(error)) => tracing::warn!(%error, "priority marks not saved"),
            Err(error) => tracing::warn!(%error, "priority marks save task failed"),
        }
    }
}

/// The marks the Mac app saved (`AgentPriorityMarks.State`, Foundation's `JSONEncoder`): a
/// snooze's `until` is a `Date`, seconds since 2001-01-01. Each field may be missing.
#[derive(Deserialize, Default)]
#[serde(default)]
struct AppMarks {
    pinned: Vec<String>,
    read: std::collections::BTreeMap<String, String>,
    snoozed: std::collections::BTreeMap<String, AppSnooze>,
    archived: Vec<String>,
    collapsed: bool,
    placed: std::collections::BTreeMap<String, i64>,
}

#[derive(Deserialize)]
struct AppSnooze {
    stamp: String,
    until: f64,
}

/// Seconds from 1970-01-01 to 2001-01-01 (Foundation's reference date).
const SINCE_1970: f64 = 978_307_200.0;

/// The marks of the app's saved copy (`AppMarks`).
pub(crate) fn from_app(value: &Value) -> Result<Marks, String> {
    let app: AppMarks =
        serde_json::from_value(value.clone()).map_err(|e| format!("importMarks: {e}"))?;
    let snoozed = app
        .snoozed
        .into_iter()
        .map(|(id, s)| {
            (id, Snooze { stamp: s.stamp, until_ms: ((s.until + SINCE_1970) * 1000.0) as i64 })
        })
        .collect();
    let placed = app
        .placed
        .into_iter()
        .filter_map(|(id, at)| usize::try_from(at).ok().map(|at| (id, at)))
        .collect();
    Ok(Marks {
        pinned: app.pinned.into_iter().collect(),
        read: app.read,
        snoozed,
        archived: app.archived.into_iter().collect(),
        collapsed: app.collapsed,
        placed,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// The marks the Mac app saved come over as they were: a snooze's `Date` (seconds since 2001)
    /// becomes epoch milliseconds, and older copies without places still load.
    #[test]
    fn the_apps_saved_marks_import_as_they_were() {
        let saved = json!({"pinned": ["a"], "read": {"b": "idle@1760000000000"},
                           "snoozed": {"c": {"stamp": "input@1759999700000", "until": 781_696_400.0}},
                           "archived": ["d"], "collapsed": true, "placed": {"e": 2, "f": -1}});
        let marks = from_app(&saved).expect("the app's marks");
        assert!(marks.pinned.contains("a") && marks.archived.contains("d") && marks.collapsed);
        assert_eq!(marks.read["b"], "idle@1760000000000");
        assert_eq!(marks.snoozed["c"].until_ms, 1_760_003_600_000);
        assert_eq!(marks.snoozed["c"].stamp, "input@1759999700000");
        assert_eq!(marks.placed.into_iter().collect::<Vec<_>>(), [("e".to_owned(), 2)]);
        let old = from_app(&json!({"pinned": ["a"], "collapsed": true})).expect("an older copy");
        assert!(old.placed.is_empty() && old.snoozed.is_empty());
        assert!(from_app(&json!({"pinned": "a"})).is_err());
    }

    /// One copy, saved: an import is taken only while the daemon has none, a change is kept in
    /// the file and a new daemon reads it back; every change is heard.
    #[tokio::test]
    async fn the_marks_are_one_copy_kept_in_the_daemons_file() {
        let dir =
            std::env::temp_dir().join(format!("acpmux-priority-marks-{}", uuid::Uuid::now_v7()));
        let path = dir.join(FILE);
        let store = MarksStore::open(Some(path.clone()));
        let mut heard = store.subscribe();
        let imported = Marks { collapsed: true, ..Marks::default() };
        assert!(store.import(imported.clone()).await);
        assert!(heard.has_changed().unwrap_or(false));
        heard.mark_unchanged();
        assert!(!store.import(Marks::default()).await, "the daemon's own marks win");
        let ((), marks) = store
            .change(|m| {
                m.toggle_pin("a");
                Ok(())
            })
            .await
            .expect("a change");
        assert!(marks.pinned.contains("a") && marks.collapsed);
        assert!(heard.has_changed().unwrap_or(false));
        assert!(store.change(|_| Err::<(), _>("no".to_owned())).await.is_err());

        let again = MarksStore::open(Some(path));
        assert_eq!(again.get(), marks, "a restart reads the file back");
        assert!(!again.import(Marks::default()).await);
        let _ = std::fs::remove_dir_all(dir);

        let memory = MarksStore::open(None);
        assert!(memory.import(imported).await, "a memory store takes an import too");
    }
}
