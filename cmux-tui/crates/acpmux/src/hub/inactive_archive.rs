//! Apply the chat menu's reversible archive tag to inactive local sessions.

use super::plan_build::ARCHIVED_TAG;
use super::*;
use std::collections::HashSet;
use std::time::Duration;

const SETTING: &str = "agents.chats.archiveInactive";
const PASS_EVERY: Duration = Duration::from_secs(10 * 60);
const FIRST_PASS_AFTER: Duration = Duration::from_secs(60);
const PASS_MAX: usize = 200;

fn archive_after(doc: &Value) -> Option<Duration> {
    let days = match crate::user_settings::value(doc, SETTING)? {
        Value::String(s) => s.strip_suffix('d').unwrap_or(&s).parse::<u64>().ok()?,
        Value::Number(n) => n.as_u64()?,
        _ => return None,
    };
    matches!(days, 1 | 2 | 7 | 14 | 30).then(|| Duration::from_secs(days * 86_400))
}

fn live_tag<'a>(m: &'a SessionMeta, key: &str, now: u64) -> Option<&'a str> {
    m.tags.get(key).filter(|t| t.expires_at.is_none_or(|at| at > now)).map(|t| t.value.as_str())
}

pub(super) const PARENT_TAGS: [&str; 5] =
    [super::views::SPAWNED_BY_TAG, "mux.parent", super::lane_reports::TAG, "side", "aside"];

// Older clients recorded links in tags, sometimes without a local parent row.
fn parents(m: &SessionMeta, now: u64) -> impl Iterator<Item = &str> {
    [
        m.lineage.as_ref().map(|link| link.parent.as_str()),
        m.subsession.as_ref().map(|link| link.started_by.as_str()),
        m.parent_id.as_deref(),
        m.lineage.as_ref().map(|link| link.root.as_str()),
    ]
    .into_iter()
    .flatten()
    .chain(PARENT_TAGS.into_iter().filter_map(move |key| live_tag(m, key, now)))
}

fn due(m: &SessionMeta, cutoff: u64, now: u64) -> bool {
    m.updated_at > 0
        && m.updated_at <= cutoff
        && m.moved_to.is_none()
        && !matches!(m.status, SessionStatus::Running | SessionStatus::Waiting)
        && live_tag(m, ARCHIVED_TAG, now).is_none()
        && live_tag(m, "pinned", now).is_none()
        && parents(m, now).next().is_none()
}

impl Hub {
    fn inactive_archive_candidates(&self, cutoff: u64, now: u64) -> (u64, Vec<Arc<Session>>) {
        let revision = self.archive_tree_revision.load(Ordering::SeqCst);
        let mut sessions = self.session_handles();
        let mut has_children = HashSet::new();
        for session in &sessions {
            session.read_meta(|m| {
                has_children.extend(parents(m, now).map(str::to_owned));
            });
        }
        sessions.retain(|s| !has_children.contains(&s.id) && s.read_meta(|m| due(m, cutoff, now)));
        (revision, sessions)
    }

    fn inactive_archive_pass(&self, after: Duration, now: u64) -> usize {
        let cutoff = now.saturating_sub(after.as_millis() as u64);
        let (revision, sessions) = self.inactive_archive_candidates(cutoff, now);
        self.archive_candidates(sessions, revision, cutoff, now)
    }

    fn archive_candidates(
        &self,
        sessions: Vec<Arc<Session>>,
        revision: u64,
        cutoff: u64,
        now: u64,
    ) -> usize {
        let mut archived = 0;
        for session in sessions {
            if self.shutting_down() || archived == PASS_MAX {
                break;
            }
            // Take the idle reaper's leases so a turn, fork or start can't begin
            // between checking for work and committing the archive.
            let Ok(_turn) = session.turn_lock.try_lock() else { continue };
            let Ok(_using) = session.harness_use.try_write() else { continue };
            let Ok(_spawn) = session.spawn_lock.try_lock() else { continue };
            if self.shown(&session)
                || self.at_work(&session).is_some()
                || self.secrets.waiting_in(&session.id)
                || session.loading.load(Ordering::SeqCst)
                || session.purged.load(Ordering::SeqCst)
                || session.replaced.load(Ordering::SeqCst)
            {
                continue;
            }
            {
                let mut m = session.meta.lock().unwrap_or_else(|error| error.into_inner());
                // A recent event, pin or new parent link wins until the tag write.
                if !due(&m, cutoff, now) {
                    continue;
                }
                let previous = m.tags.insert(
                    ARCHIVED_TAG.into(),
                    crate::store::Tag { value: now.to_string(), expires_at: None },
                );
                // A local child may have appeared since the tree was read. Validate
                // after inserting, while the tentative tag is still private to this lock.
                if self.archive_tree_revision.load(Ordering::SeqCst) != revision {
                    match previous {
                        Some(tag) => {
                            m.tags.insert(ARCHIVED_TAG.into(), tag);
                        }
                        None => {
                            m.tags.remove(ARCHIVED_TAG);
                        }
                    }
                    break;
                }
            }
            match self.persist_tags(&session) {
                Ok(()) => archived += 1,
                Err(e) => tracing::warn!(session = %session.id, "inactive archive: {}", e.message),
            }
        }
        archived
    }

    // Started after log recovery. A disabled pass reads only the setting, and
    // cancelling the daemon scope ends the worker.
    pub(crate) fn inactive_archive_worker(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        self.scope.spawn_until_cancelled("inactive-archive", async move {
            let mut wait = FIRST_PASS_AFTER;
            loop {
                tokio::time::sleep(wait).await;
                wait = PASS_EVERY;
                let Some(hub) = weak.upgrade() else { return };
                if hub.shutting_down() {
                    return;
                }
                let pass = tokio::task::spawn_blocking(move || {
                    if let crate::user_settings::Settings::Parsed(doc) =
                        crate::user_settings::read()
                        && let Some(after) = archive_after(&doc)
                    {
                        hub.inactive_archive_pass(after, now_ms());
                    }
                });
                if let Err(e) = pass.await {
                    tracing::warn!("inactive archive pass: {e}");
                }
            }
        });
    }
}

#[cfg(test)]
#[path = "inactive_archive_tests.rs"]
mod tests;
