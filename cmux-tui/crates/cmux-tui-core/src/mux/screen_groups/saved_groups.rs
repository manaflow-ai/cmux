//! Saved screen groups: session-wide records of a group's name, color and
//! members that outlive their screens; save, unsave, delete and reopen.

use super::*;

impl Mux {
    pub(super) fn saved_members(&self, members: &[ScreenId]) -> Vec<SavedScreenMember> {
        let presentation = self.presentation_snapshot();
        self.with_state(|state| {
            members
                .iter()
                .filter_map(|screen| {
                    let (wi, si) = locate_screen(state, *screen)?;
                    let screen = &state.workspaces[wi].screens[si];
                    let record = presentation
                        .screens
                        .screen(screen.public_id.as_str())
                        .cloned()
                        .unwrap_or_default();
                    let cwd = state
                        .panes
                        .get(&screen.active_pane)
                        .and_then(|pane| pane.tabs.get(pane.active_tab))
                        .and_then(|surface| state.surfaces.get(surface))
                        .and_then(|runtime| runtime.presented_directory());
                    Some(SavedScreenMember {
                        name: screen.name.clone(),
                        color: record.color,
                        icon: record.icon,
                        cwd,
                    })
                })
                .collect()
        })
    }

    pub(super) fn sync_saved_screen_group(&self, group: &str) -> anyhow::Result<()> {
        let outcome = self.screen_group_outcome(group);
        let Some(record) = outcome.group else { return Ok(()) };
        let Some(saved_id) = record.saved_id.clone() else { return Ok(()) };
        let profile_id = self
            .presentation_snapshot()
            .saved_screen_groups
            .iter()
            .find(|saved| saved.id == saved_id)
            .and_then(|saved| saved.profile_id.clone());
        let saved = SavedScreenGroupRecord {
            id: saved_id,
            name: record.name,
            color: record.color,
            profile_id,
            members: self.saved_members(&outcome.members),
            updated_at_ms: crate::workspace_registry::unix_epoch_ms()?,
        };
        let mut registry = self.workspace_registry.lock().unwrap();
        registry.put_saved_screen_group(&saved)?;
        self.reload_presentation(&registry)
    }

    /// Save a group: a session-wide record linked to the live group.
    pub fn save_screen_group_as(&self, actor: &Actor, group: &str) -> anyhow::Result<String> {
        let saved_id = self.commit_screen_metadata(actor, |_, screens| {
            let record = screens
                .groups
                .get_mut(group)
                .with_context(|| format!("unknown screen group {group}"))?;
            Ok(record.saved_id.get_or_insert_with(new_saved_screen_group_id).clone())
        })?;
        self.sync_saved_screen_group(group)?;
        self.emit(MuxEvent::TreeChanged);
        Ok(saved_id)
    }

    /// Unsave a live group: delete its saved record and unlink it.
    pub fn unsave_screen_group(&self, group: &str) -> anyhow::Result<()> {
        let saved = self
            .presentation_snapshot()
            .screens
            .groups
            .get(group)
            .with_context(|| format!("unknown screen group {group}"))?
            .saved_id
            .clone()
            .context("bad request: the screen group is not saved")?;
        self.delete_saved_screen_group(&saved)?;
        Ok(())
    }

    pub fn delete_saved_screen_group(&self, saved: &str) -> anyhow::Result<bool> {
        let removed = {
            let mut registry = self.workspace_registry.lock().unwrap();
            let removed = registry.delete_saved_screen_group(saved)?;
            self.reload_presentation(&registry)?;
            removed
        };
        anyhow::ensure!(removed, "unknown saved screen group {saved}");
        self.publish_journal_event();
        self.emit(MuxEvent::TreeChanged);
        Ok(removed)
    }

    /// Reopen a saved group into `workspace`: one new screen per member, in
    /// the member's directory, with its name, color, and icon, grouped and
    /// linked to the saved record. An open group is returned as it is.
    pub fn reopen_saved_screen_group_as(
        self: &Arc<Self>,
        actor: &Actor,
        saved: &str,
        workspace: WorkspaceId,
    ) -> anyhow::Result<ScreenGroupOutcome> {
        let presentation = self.presentation_snapshot();
        let record = presentation
            .saved_screen_groups
            .iter()
            .find(|candidate| candidate.id == saved)
            .cloned()
            .with_context(|| format!("unknown saved screen group {saved}"))?;
        if let Some(open) = presentation
            .screens
            .groups
            .values()
            .find(|group| group.saved_id.as_deref() == Some(saved))
        {
            return Ok(self.screen_group_outcome(&open.id));
        }
        let mut created = Vec::new();
        for member in &record.members {
            let spec = ScreenSpec {
                name: member.name.clone(),
                color: member.color.clone(),
                icon: member.icon.clone(),
                ..ScreenSpec::default()
            };
            let spawn = TerminalSpawnOptions::new(member.cwd.clone(), Vec::new());
            let (_, screen) =
                self.new_screen_with_spec_as(actor, Some(workspace), spawn, None, spec)?;
            created.push(screen);
        }
        anyhow::ensure!(!created.is_empty(), "bad request: the saved screen group has no members");
        let outcome = self.create_screen_group_as(
            actor,
            &created,
            Some(record.name.clone()),
            Some(record.color),
        )?;
        let group = outcome
            .group
            .as_ref()
            .map(|group| group.id.clone())
            .context("screen group disappeared")?;
        self.commit_screen_metadata(actor, |_, screens| {
            if let Some(live) = screens.groups.get_mut(&group) {
                live.saved_id = Some(saved.to_string());
            }
            Ok(())
        })?;
        self.emit(MuxEvent::TreeChanged);
        Ok(self.screen_group_outcome(&group))
    }
}
