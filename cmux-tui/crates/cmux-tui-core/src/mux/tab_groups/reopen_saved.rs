//! Reopening a saved tab group (moved out of tab_groups.rs for P8 landing
//! 3b, behavior unchanged).

use super::*;

impl Mux {
    /// Reopen a saved group into `pane`. A live group already linked to the
    /// record is returned unchanged. Otherwise each member is restored: a
    /// terminal still running is reattached (a new view of the same
    /// terminal), other terminals start in their saved directory, and
    /// browsers reopen at their saved URL.
    pub fn reopen_saved_tab_group_as(
        self: &Arc<Self>,
        actor: &Actor,
        saved_id: &str,
        pane: PaneId,
        transaction: Option<&str>,
    ) -> anyhow::Result<TabGroupOutcome> {
        let presentation = self.presentation_snapshot();
        let saved = presentation
            .saved_tab_groups
            .iter()
            .find(|record| record.id == saved_id)
            .cloned()
            .ok_or_else(|| crate::state::commit::state_not_found("saved_tab_group", saved_id))?;
        if let Some(live) = presentation
            .tab_groups
            .groups
            .values()
            .find(|group| group.saved_id.as_deref() == Some(saved_id))
        {
            return Ok(self.tab_group_outcome(&live.id));
        }
        anyhow::ensure!(
            self.with_state(|state| state.panes.contains_key(&pane)),
            "unknown pane {pane}"
        );
        let mut surfaces = Vec::new();
        for member in &saved.members {
            let surface = match member {
                SavedTabMember::Terminal { terminal_id, cwd, .. } => {
                    let reattached = terminal_id
                        .as_deref()
                        .and_then(|terminal| self.resolve_terminal(terminal).ok().flatten())
                        .filter(|resolution| {
                            resolution.terminal.lifecycle == TerminalLifecycle::Running
                        })
                        .and_then(|resolution| {
                            self.project_terminal_into_pane(
                                actor,
                                &resolution.terminal.terminal_id,
                                pane,
                            )
                            .ok()
                        });
                    match reattached {
                        Some(surface) => surface,
                        None => self.new_tab_as(actor, Some(pane), cwd.clone(), None)?.id,
                    }
                }
                SavedTabMember::Browser { url, engine, profile_id, title } => match engine {
                    Some(engine) => {
                        self.new_frontend_browser_tab_as(
                            actor,
                            Some(pane),
                            crate::workspace_registry::FrontendBrowserRecord {
                                engine: engine.clone(),
                                url: url.clone(),
                                title: title.clone(),
                                favicon_url: None,
                                profile_id: profile_id.clone(),
                                // The app that shows the reopened tab claims it.
                                owner: None,
                            },
                            None,
                        )?
                        .id
                    }
                    None => self.new_browser_tab_as(actor, url.clone(), Some(pane), None)?.id,
                },
            };
            surfaces.push(surface);
        }
        let outcome = self.create_tab_group_as(
            actor,
            &surfaces,
            Some(saved.name),
            Some(saved.color),
            None,
            transaction,
        )?;
        let group = outcome
            .group
            .as_ref()
            .map(|group| group.id.clone())
            .context("reopened group missing")?;
        let link = saved_id.to_string();
        let room = saved.room;
        let linked = group.clone();
        self.commit_tab_strip_change(
            StripRequest::local(actor, "tab.group.save"),
            None,
            move |mux, state, edit| {
                let group = linked;
                if let Some(record) = edit.groups.groups.get_mut(&group) {
                    record.saved_id = Some(link.clone());
                }
                if let Some(mut record) = mux.saved_record_for(state, &edit.groups, &group) {
                    record.room = room;
                    edit.saved = Some(record);
                }
                Ok(())
            },
        )?;
        Ok(self.tab_group_outcome(&group))
    }
}
