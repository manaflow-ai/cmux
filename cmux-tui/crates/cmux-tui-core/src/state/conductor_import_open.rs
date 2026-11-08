//! A worktree already open in cmux is not a new workspace to import, even
//! when it was opened without this importer or the source's identity changed.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use cmux_conductor_import::plan::{Disposition, Plan};

use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::resource_operation_error;

impl Mux {
    pub(crate) fn exclude_open_import_workspaces(
        &self,
        plan: &mut Plan,
    ) -> Result<(), ResourceError> {
        let cleanup: BTreeSet<_> = plan.cleanup.iter().collect();
        let (ids, surfaces) = self.with_state(|state| {
            let mut ids = BTreeMap::new();
            let mut surfaces = Vec::new();
            for workspace in &state.workspaces {
                // Interrupted imports deliberately replace their own half-made
                // workspace. Another open workspace at that path still counts.
                if cleanup.contains(&workspace.key)
                    || cleanup.contains(&workspace.public_id.to_string())
                {
                    continue;
                }
                ids.insert(workspace.public_id.to_string(), workspace.key.clone());
                for screen in &workspace.screens {
                    for pane in
                        screen.root.pane_ids_vec().iter().filter_map(|id| state.panes.get(id))
                    {
                        for surface in pane.tabs.iter().filter_map(|id| state.surfaces.get(id)) {
                            surfaces.push((workspace.key.clone(), surface.clone()));
                        }
                    }
                }
            }
            (ids, surfaces)
        });
        let mut paths = self
            .read_registry_state(|connection| {
                let mut statement =
                    connection.prepare("SELECT workspace_id, path FROM workspace_agent_folder")?;
                let rows = statement.query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                })?;
                let mut paths = Vec::new();
                for row in rows {
                    let (id, path) = row?;
                    if let Some(key) = ids.get(&id) {
                        paths.push((PathBuf::from(path), key.clone()));
                    }
                }
                Ok(paths)
            })
            .map_err(resource_operation_error)?;
        paths.extend(surfaces.into_iter().filter_map(|(key, surface)| {
            surface.local_cwd().map(|path| (PathBuf::from(path), key))
        }));
        // Resolve aliases outside both the state and registry locks.
        let paths: BTreeMap<_, _> = paths
            .into_iter()
            .filter_map(|(path, key)| std::fs::canonicalize(path).ok().map(|path| (path, key)))
            .collect();
        for project in &mut plan.projects {
            for workspace in &mut project.workspaces {
                if workspace.disposition != Disposition::Adopt {
                    continue;
                }
                let Some(path) =
                    workspace.path.as_ref().and_then(|path| std::fs::canonicalize(path).ok())
                else {
                    continue;
                };
                if let Some((_, key)) =
                    paths.range(path.clone()..).next().filter(|(open, _)| open.starts_with(&path))
                {
                    workspace.disposition =
                        Disposition::AlreadyImported { cmux_workspace: key.clone() };
                    workspace.checked = false;
                }
            }
        }
        Ok(())
    }
}
