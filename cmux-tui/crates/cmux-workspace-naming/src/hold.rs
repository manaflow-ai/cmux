//! The last name each tab gave a workspace's row (`WorkspaceAutoNameHold`), so the row keeps it
//! while that tab's name is briefly unknown (a relaunch, a watch reconnect before the first page
//! of turns).

use std::collections::HashMap;

/// One app's held names.
#[derive(Debug, Default)]
pub struct Hold {
    /// By workspace id, then by namer (the tab and chat that named it): the name it gave last.
    held: HashMap<String, HashMap<String, String>>,
    /// By workspace id: the launch name and chat of a workspace its launcher named after that
    /// chat's agent, so it keeps following the agent once acpmux drops the launch name from
    /// the agent's former names.
    launcher_named: HashMap<String, String>,
}

impl Hold {
    /// The name a row shows: `label` when its namer gives one (held from now on), else the
    /// name the same namer gave last, else `None`.
    pub fn settle(
        &mut self,
        workspace: &str,
        namer: &str,
        label: Option<String>,
    ) -> Option<String> {
        let Some(label) = label else {
            return self.held.get(workspace)?.get(namer).cloned();
        };
        self.held.entry(workspace.to_owned()).or_default().insert(namer.to_owned(), label.clone());
        Some(label)
    }

    /// Whether `workspace`, named `name`, is launcher-named after the agent of `session`:
    /// `matches` now, or it matched before under the same name and chat. Remembers a match.
    pub fn launcher_named(
        &mut self,
        workspace: &str,
        name: &str,
        session: &str,
        matches: bool,
    ) -> bool {
        let key = format!("{session}\0{name}");
        if matches {
            self.launcher_named.insert(workspace.to_owned(), key);
            return true;
        }
        self.launcher_named.get(workspace) == Some(&key)
    }

    /// The person named `workspace`: nothing held for it outlives that name.
    pub fn forget(&mut self, workspace: &str) {
        self.held.remove(workspace);
    }
}
