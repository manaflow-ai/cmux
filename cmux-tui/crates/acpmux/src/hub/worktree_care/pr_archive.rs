//! A PR archive may release only its idle, managed checkout. The care policy
//! rechecks the recorded identity and the Git contents at each scan.
use super::*;
use crate::hub::auto_settle::{Rules, SETTLED_TAG, read_rules};
use cmux_worktree_care::policy::{ArchivedCheckout, Session as CareSession};
use cmux_worktree_care::store::inside_folder;
use std::path::Path;

pub(super) fn managed_root(home: &Path) -> Option<PathBuf> {
    let base = cmux_git::worktree_root::worktree_root_path(&home.canonicalize().ok()?);
    let path = base.canonicalize().ok()?;
    (path == base || path == base.with_file_name(cmux_git::worktree_root::NOINDEX_NAME))
        .then_some(path)
}

impl Hub {
    pub(super) fn care_sessions(&self, managed: Option<&Path>, rules: &Rules) -> Vec<CareSession> {
        let sessions: Vec<_> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        sessions
            .into_iter()
            .map(|session| {
                let mut row = session.read_meta(|m| CareSession {
                    name: m.name.clone(),
                    cwd: m.cwd.clone(),
                    open: m.status != SessionStatus::Closed,
                    updated_ms: m.updated_at,
                    archived_checkout: managed.and_then(|root| checkout(m, root, rules)),
                    ids: std::iter::once(&m.id)
                        .chain(m.agent_session_id.as_ref())
                        .chain(&m.previous_agent_session_ids)
                        .cloned()
                        .collect(),
                });
                if row.archived_checkout.is_some() && self.settle_blocked(&session) {
                    row.archived_checkout = None;
                }
                row
            })
            .collect()
    }

    /// Unarchive, a new session in the folder, or disabling the rule during
    /// the scan wins. Other daemons' open sessions always retain their folder.
    pub(super) fn recheck_pr_archive(
        &self,
        expected: &ArchivedCheckout,
        home: &Path,
        managed: Option<&Path>,
    ) -> Result<(), String> {
        let root = &expected.root;
        let rules = read_rules();
        let (actual_root, common_dir) = crate::git_state::linked_worktree(root)
            .ok_or("the checkout is no longer a linked worktree")?;
        let (branch, head) = {
            let state = crate::git_state::GitState::read(root);
            (state.branch, state.head)
        };
        let mut matched = false;
        for s in self.care_sessions(managed, &rules) {
            if !s.open || !inside_folder(&s.cwd, root) {
                continue;
            }
            let Some(c) = s.archived_checkout else {
                return Err("a chat is using the checkout".into());
            };
            if &c != expected
                || matched
                || c.root != actual_root
                || c.common_dir != common_dir
                || Some(c.branch) != branch
                || Some(c.head) != head
            {
                return Err("the archived checkout changed".into());
            }
            matched = true;
        }
        if !matched
            || crate::worktree_sessions::on_disk(home, Some(&crate::config::home()))
                .iter()
                .any(|s| s.open && inside_folder(&s.cwd, root))
        {
            return Err("the checkout is no longer free for PR archive cleanup".into());
        }
        Ok(())
    }
}

fn checkout(meta: &SessionMeta, managed: &Path, rules: &Rules) -> Option<ArchivedCheckout> {
    if meta.status != SessionStatus::Idle || meta.remote_origin {
        return None;
    }
    if super::super::auto_settle::Facts::of(meta).never {
        return None;
    }
    let tags =
        |key: &str| meta.tags.get(key).filter(|t| t.expires_at.is_none()).map(|t| t.value.as_str());
    tags(super::super::plan_build::ARCHIVED_TAG)?;
    match tags(SETTLED_TAG)? {
        "merged" if rules.on_merge => {}
        "closed" if rules.on_close => {}
        _ => return None,
    }
    let origin = meta.worktree.as_ref()?;
    if origin.cwd != meta.cwd || origin.root.parent()?.parent()? != managed {
        return None;
    }
    let branch = origin.branch.as_ref()?;
    if branch.strip_prefix("cmux/")? != origin.root.file_name()?.to_str()? {
        return None;
    }
    Some(ArchivedCheckout {
        root: origin.root.clone(),
        common_dir: origin.common_dir.clone(),
        head: origin.head.clone()?,
        branch: branch.clone(),
    })
}
