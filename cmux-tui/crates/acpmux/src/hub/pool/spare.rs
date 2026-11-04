//! Spares: one hidden session per harness this machine used, of the shape of
//! that harness's newest session and in its folder, so the next new session
//! of the harness (`acpmux ensure`, a Cloud chat's first start) takes a
//! running agent instead of paying the cold start (spawn, the harness's own
//! start, `initialize`, the harness session). It is the pool's third role
//! (`policy::Role::Spare`) and lives under the pool's rules: hidden, matched
//! by the exact key, ended at shutdown, under the RSS cap, never for a
//! remote-origin chain.
//!
//! Why the whole session and not a bare process waiting for its folder: the
//! harness command carries the session's id and name in its environment, its
//! process starts in the session's folder, and Claude Code takes its session
//! id on its command line, so nothing safe can be started before the folder
//! is known. The folder the harness's last session used is the guess; a
//! machine whose chats always start in one folder (a Cloud machine's home
//! folder) always hits.
//!
//! Lifecycle: a person's new session of a harness wants a spare of its shape
//! (`spare_note_used`), which replaces that harness's spare in another folder;
//! taking it leaves the entry empty and the taking session's own creation
//! wants it again, so the spare refills in the background. It exits after
//! `pool.spareIdleMinutes` (default 60) unused; a machine that never ran a
//! harness never gets one. The harnesses used are remembered in
//! `<acpmux home>/pool-spares.json`, so a restarted daemon (a resumed or
//! freshly booted Cloud machine) starts them again once startup is done
//! (`restore_spares`). A spare whose agent died is removed at the pool's next
//! RSS tick (`spare_replace_dead`) and started again by the spare worker, in its
//! harness's newest shape. Only a session that could have taken a pooled agent
//! (no env, route, disallowed tools or extra folders of its own) is remembered,
//! with its model request. Off with `pool.spare: false` or
//! `ACPMUX_SPARE_HARNESS=0` in the daemon's environment.

use super::*;

/// A remembered harness older than this starts no spare at daemon start.
const RECENT: Duration = Duration::from_secs(7 * 24 * 3600);
const FILE: &str = "pool-spares.json";

/// One remembered harness in `pool-spares.json`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Remembered {
    pub harness: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preset: Option<String>,
    pub cwd: PathBuf,
    /// The session's model request: part of the spawn for a harness that takes its model there.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    pub used_at_ms: u64,
}

#[derive(Debug, Default, serde::Serialize, serde::Deserialize)]
struct SpareFile {
    #[serde(default)]
    spares: Vec<Remembered>,
}

fn file_path() -> PathBuf {
    crate::config::home().join(FILE)
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// `list` with `entry` as its harness's one remembered shape, unless a newer one is there.
pub(super) fn remember(list: &mut Vec<Remembered>, entry: Remembered) {
    if list.iter().any(|r| r.harness == entry.harness && r.used_at_ms > entry.used_at_ms) {
        return;
    }
    list.retain(|r| r.harness != entry.harness);
    list.push(entry);
}

/// The remembered shapes still recent at `now_ms`.
pub(super) fn recent(list: &[Remembered], now_ms: u64) -> Vec<Remembered> {
    let window = u64::try_from(RECENT.as_millis()).unwrap_or(u64::MAX);
    list.iter().filter(|r| now_ms.saturating_sub(r.used_at_ms) <= window).cloned().collect()
}

fn read_file(path: &Path) -> Vec<Remembered> {
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice::<SpareFile>(&b).ok())
        .map(|f| f.spares)
        .unwrap_or_default()
}

fn write_file(path: &Path, spares: Vec<Remembered>) -> std::io::Result<()> {
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let bytes = serde_json::to_vec(&SpareFile { spares }).map_err(std::io::Error::other)?;
    let n = SEQ.fetch_add(1, Ordering::Relaxed);
    let tmp = path.with_extension(format!("json.{}.{n}.tmp", std::process::id()));
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

impl Hub {
    async fn spare_enabled(&self) -> bool {
        self.config.read().await.pool.spare_enabled() && self.pool_enabled().await
    }

    /// The remembered shapes, read from `pool-spares.json` on first use, after `change`.
    /// Blocking (the first read, and a write when `change` changed something).
    fn spares_with(&self, change: impl FnOnce(&mut Vec<Remembered>)) -> Vec<Remembered> {
        let _file = lock(&self.pool.spare_file);
        let (list, changed) = {
            let mut g = lock(&self.pool.spares);
            let list = g.get_or_insert_with(|| read_file(&file_path()));
            let before = list.clone();
            change(list);
            (list.clone(), *list != before)
        };
        if changed && let Err(e) = write_file(&file_path(), list.clone()) {
            tracing::debug!("{FILE}: {e}");
        }
        list
    }

    /// A person's local session of `harness`/`preset` that could have taken a pooled agent was
    /// created in `cwd`: remember the shape and keep a spare of it (replacing that harness's
    /// spare in another folder).
    pub(super) fn spare_note_used(
        self: &Arc<Self>,
        harness: &str,
        preset: Option<String>,
        cwd: PathBuf,
        model: Option<String>,
    ) {
        let hub = self.clone();
        let entry =
            Remembered { harness: harness.to_owned(), preset, cwd, model, used_at_ms: now_ms() };
        tokio::spawn(async move {
            if !hub.spare_enabled().await {
                return;
            }
            let harness = entry.harness.clone();
            let h = hub.clone();
            let Ok(list) =
                tokio::task::spawn_blocking(move || h.spares_with(|l| remember(l, entry))).await
            else {
                return;
            };
            // The newest shape, so two quick sessions never leave the older one's spare.
            if let Some(r) = list.into_iter().find(|r| r.harness == harness) {
                hub.spare_want(r).await;
            }
        });
    }

    /// Want the spare for this shape (its start runs in the background).
    async fn spare_want(self: &Arc<Self>, r: Remembered) {
        let Remembered { harness, preset, cwd, model, .. } = r;
        match self.pool_spec_in(Some(harness.clone()), preset, cwd, Some(model)).await {
            Ok(spec) => self.pool_want(Role::Spare, spec).await,
            Err(e) => tracing::debug!(%harness, "no spare: {}", e.message),
        }
    }

    /// Daemon start, once startup is done: a spare for each harness used in the last week, in the
    /// folder its newest session used (a resumed or freshly booted machine has one ready). A
    /// harness that already has a spare (a session came first) keeps it.
    pub(crate) async fn restore_spares(self: &Arc<Self>) {
        self.wait_startup().await;
        // Always: spares (or the pool) may be switched on by a config reload later; the worker
        // checks the switch each time it wakes.
        tokio::spawn(self.clone().spare_worker());
        if !self.spare_enabled().await {
            return;
        }
        let h = self.clone();
        let list =
            tokio::task::spawn_blocking(move || h.spares_with(|_| {})).await.unwrap_or_default();
        for r in recent(&list, now_ms()) {
            if !r.cwd.is_dir() || lock(&self.pool.pool).has_spare(&r.harness) {
                continue;
            }
            tracing::info!(harness = %r.harness, "a spare starts for a harness this machine used");
            self.spare_want(r).await;
        }
    }

    /// Ready entries whose agent died are removed (their hosts ended); each spare among them
    /// starts again, from the spare worker.
    pub(super) async fn spare_replace_dead(self: &Arc<Self>) {
        let ready: Vec<(String, Arc<ChildAgent>)> = lock(&self.pool.pool)
            .ready_mut()
            .map(|p| (p.session_id.clone(), p.child.clone()))
            .collect();
        let mut dead = Vec::new();
        for (id, child) in ready {
            if !child.is_alive().await {
                dead.push(id);
            }
        }
        if dead.is_empty() {
            return;
        }
        let (removed, restart) = {
            let mut pool = lock(&self.pool.pool);
            let mut removed = Vec::new();
            for id in &dead {
                if let Some(p) = pool.remove_ready(|p| &p.session_id == id) {
                    removed.push(p);
                }
            }
            let keys: Vec<PoolKey> = removed.iter().map(|p| p.key.clone()).collect();
            let restart: Vec<String> = pool
                .empty_spares()
                .into_iter()
                .filter(|k| keys.contains(k))
                .map(|k| k.harness)
                .collect();
            (removed, restart)
        };
        tracing::info!(count = removed.len(), "pooled agents died; they are removed");
        self.pool_discard(removed);
        if !restart.is_empty() {
            {
                let mut queue = lock(&self.pool.spare_restart);
                for h in restart {
                    if !queue.contains(&h) {
                        queue.push(h);
                    }
                }
            }
            self.pool.spare_wake.notify_one();
        }
    }

    /// Starts again the spares `spare_replace_dead` found dead, in the harness's newest shape.
    /// Its own task (from `restore_spares`, at daemon start), so the pool's RSS pass never awaits a pooled start: that start ends in the
    /// RSS pass, and the two futures would contain each other.
    async fn spare_worker(self: Arc<Self>) {
        loop {
            // Never on `shutdown` or `pool.stop`: their stored permits belong to the daemon's own
            // waiters. A stopping pool starts nothing (`pool_want`), and the task ends with it.
            self.pool.spare_wake.notified().await;
            if self.pool.stopping.load(Ordering::SeqCst) || self.stopping.load(Ordering::SeqCst) {
                return;
            }
            let harnesses = std::mem::take(&mut *lock(&self.pool.spare_restart));
            if !self.spare_enabled().await {
                continue;
            }
            let shapes = lock(&self.pool.spares).clone().unwrap_or_default();
            for r in shapes.into_iter().filter(|r| harnesses.contains(&r.harness)) {
                tracing::info!(harness = %r.harness, "a spare whose agent died starts again");
                self.spare_want(r).await;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(harness: &str, cwd: &str, at: u64) -> Remembered {
        Remembered {
            harness: harness.into(),
            preset: None,
            cwd: cwd.into(),
            model: None,
            used_at_ms: at,
        }
    }

    #[test]
    fn each_harness_is_remembered_once_with_its_newest_folder() {
        let mut list = vec![r("claude", "/a", 1), r("codex", "/a", 2)];
        remember(&mut list, r("claude", "/b", 3));
        assert_eq!(list, vec![r("codex", "/a", 2), r("claude", "/b", 3)]);
    }

    #[test]
    fn an_older_shape_arriving_late_never_replaces_a_newer_one() {
        let mut list = vec![r("claude", "/b", 5)];
        remember(&mut list, r("claude", "/a", 4));
        assert_eq!(list, vec![r("claude", "/b", 5)]);
    }

    #[test]
    fn only_a_harness_used_in_the_last_week_starts_a_spare() {
        let week = u64::try_from(RECENT.as_millis()).unwrap();
        let list = vec![r("claude", "/a", 10), r("codex", "/a", week + 20)];
        assert_eq!(recent(&list, week + 30), vec![r("codex", "/a", week + 20)]);
    }

    #[test]
    fn the_file_round_trips_and_a_bad_file_reads_as_none() {
        let dir = std::env::temp_dir().join(format!("acpmux-spares-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(FILE);
        assert!(read_file(&path).is_empty());
        write_file(&path, vec![r("claude", "/a", 1)]).unwrap();
        assert_eq!(read_file(&path), vec![r("claude", "/a", 1)]);
        std::fs::write(&path, b"{not json").unwrap();
        assert!(read_file(&path).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
