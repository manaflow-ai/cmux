//! Part of `Hub`; see `hub/mod.rs`. The idle pass's census of what runs under an idle harness:
//! what it judges by (the MCP servers, `LaunchServers`, `StoredLaunch`) is in `sidecar_census.rs`.

#![cfg_attr(not(unix), allow(dead_code))]

use super::*;
pub(crate) use crate::sidecar_census::Census;
pub(crate) use crate::sidecar_census::LaunchServers;
#[cfg(unix)]
use crate::sidecar_census::classify;
use crate::sidecar_census::{CENSUS_BUDGET, Servers, from_json, launch_only, resolved};
pub use crate::sidecar_census::{Sidecar, StoredLaunch};

/// A refusal is logged at most this often per session.
const REFUSAL_LOG_EVERY: std::time::Duration = std::time::Duration::from_secs(600);

impl Hub {
    /// Lists what runs under `pid`, the session's harness, against `sidecars`, within
    /// [`CENSUS_BUDGET`].
    pub(super) async fn idle_census(&self, pid: Option<u32>, sidecars: Option<Servers>) -> Census {
        #[cfg(unix)]
        if let (Some(pid), Some(sidecars)) = (pid, sidecars) {
            // The listing, each candidate's argv and the match all run in the bounded task.
            let census = tokio::task::spawn_blocking(move || {
                // A reading shared with the pass's other censuses (`agent_host/proc_table.rs`).
                let found = crate::agent_host::tree::under_shared(pid)?;
                let (list, path) = (&sidecars.list, sidecars.path.as_deref());
                Some(classify(&found, pid, list, path, crate::agent_host::tree::identity))
            });
            return match tokio::time::timeout(CENSUS_BUDGET, census).await {
                Ok(Ok(Some(census))) => census,
                _ => Census::Unknown,
            };
        }
        // Windows: no census, and closing the job ends everything under it.
        #[cfg(not(unix))]
        let _ = (pid, sidecars);
        Census::Unknown
    }

    /// Logs why an idle harness stays up, once per [`REFUSAL_LOG_EVERY`] per session.
    pub(super) fn note_refusal(&self, session: &Session, census: &Census) {
        let now = self.clock_now();
        let last = session.idle_refusal_logged.load(Ordering::Relaxed);
        if last != 0 && now.saturating_sub(last) < REFUSAL_LOG_EVERY.as_nanos() as u64 {
            return;
        }
        session.idle_refusal_logged.store(now.max(1), Ordering::Relaxed);
        match census {
            Census::Busy { pid, comm } => tracing::info!(
                session = %session.id, pid, comm = %comm,
                "idle harness stays up: a process that is not one of its MCP servers runs under it"
            ),
            Census::Unknown => tracing::info!(
                session = %session.id,
                "idle harness stays up: its MCP servers or the processes under it are not known"
            ),
            Census::Clear => {}
        }
    }

    /// The MCP servers `child`, the session's harness, runs: what its configs named as it
    /// started (`LaunchServers::read`) and the `mcpServers` acpmux gave it. None when its configs
    /// were not read in time: the harness stays up. For a
    /// harness another daemon started none are known, so it ends only when nothing at all runs
    /// under it.
    pub(super) async fn sidecars(&self, child: &ChildAgent) -> Option<Servers> {
        let state = child.launch.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let (mut servers, path, cwd) = match state {
            None => return Some(Servers { list: Vec::new(), path: None }),
            Some(LaunchServers::Known { servers, path, cwd }) => (servers, path, cwd),
            Some(LaunchServers::Unknown) => return None,
        };
        let given = child.given_servers.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let read = tokio::task::spawn_blocking(move || {
            servers.extend(resolved(from_json(given.as_ref()), &path, &cwd));
            Servers { list: servers, path: Some(path) }
        });
        tokio::time::timeout(CENSUS_BUDGET, read).await.ok()?.ok()
    }
}

impl ChildAgent {
    /// Records `servers`, what its configs named as it started (`LaunchServers::read`).
    pub(crate) fn record_launch(&self, servers: LaunchServers) {
        *self.launch.lock().unwrap_or_else(|e| e.into_inner()) = Some(servers);
    }
}

impl Hub {
    /// Keeps what the census knows of `child`'s servers in `session`'s meta (saved by the
    /// caller), or clears it: a direct child or one whose configs were not read leaves nothing
    /// for a next daemon.
    pub(super) fn note_launch(&self, session: &Session, child: &ChildAgent) {
        let launch = child.launch.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let stored = match (child.host_record(), launch) {
            (Some(record), Some(LaunchServers::Known { servers, path, cwd })) => {
                Some(StoredLaunch {
                    incarnation: record.incarnation,
                    servers,
                    path,
                    cwd,
                    given: launch_only(
                        child.given_servers.lock().unwrap_or_else(|e| e.into_inner()).as_ref(),
                    ),
                })
            }
            _ => None,
        };
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).idle_launch = stored;
    }

    /// An adopted host's servers, from its session's meta when they were kept for this
    /// `incarnation`: the idle census then judges it as the daemon that started it did. When
    /// none were kept (a host an older build started), they are read from the running harness
    /// (`LaunchServers::read_live`, for a profile of `kind`) and kept for the next daemon. Before,
    /// such a harness knew no server, so the one its user config names (a `.claude.json` server)
    /// kept it up for good: 27 idle harnesses, 8.3 GB, on one lane VM (2026-11-03).
    pub(super) async fn restore_launch(
        &self,
        session: &Session,
        child: &ChildAgent,
        incarnation: &str,
        kind: Option<crate::config::HarnessKind>,
    ) {
        if let Some(stored) = session.meta().idle_launch.filter(|l| l.incarnation == incarnation) {
            child.record_launch(LaunchServers::Known {
                servers: stored.servers,
                path: stored.path,
                cwd: stored.cwd,
            });
            *child.given_servers.lock().unwrap_or_else(|e| e.into_inner()) = stored.given;
            return;
        }
        #[cfg(unix)]
        if let (Some(pid), Some(kind)) = (child.pid, kind) {
            let meta = session.meta();
            let family = meta.family.clone().unwrap_or_default();
            if let Some(read) = LaunchServers::read_live(pid, meta.cwd.clone(), family, kind).await
            {
                child.record_launch(read);
                self.note_launch(session, child);
                self.save_meta(session);
            }
        }
        #[cfg(not(unix))]
        let _ = kind;
    }
}
