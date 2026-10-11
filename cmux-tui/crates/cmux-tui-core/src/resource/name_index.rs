//! Name resolution and the public slot indexes (moved out of resource.rs,
//! behavior unchanged).

use std::collections::HashMap;

use super::{
    ContentPublicId, PanePublicId, ResourceError, ScreenPublicId, SplitPublicId, TabPublicId,
    WorkspacePublicId,
};
use crate::{PaneId, ScreenId, SplitId, SurfaceId, WorkspaceId};

pub fn resolve_name<T: Clone>(
    kind: &str,
    selector: &str,
    candidates: impl IntoIterator<Item = (String, Option<String>, T)>,
) -> Result<T, ResourceError> {
    let mut matches = candidates
        .into_iter()
        .filter(|(_, name, _)| name.as_deref() == Some(selector))
        .collect::<Vec<_>>();
    match matches.len() {
        0 => Err(ResourceError::not_found(kind, selector)),
        1 => Ok(matches.pop().expect("one match").2),
        _ => {
            let mut ids = matches.into_iter().map(|(id, _, _)| id).collect::<Vec<_>>();
            ids.sort();
            Err(ResourceError::ambiguous(kind, selector, ids))
        }
    }
}

#[derive(Debug, Default, Clone)]
pub struct PublicSlotIndexes {
    pub workspaces: HashMap<WorkspacePublicId, WorkspaceId>,
    pub screens: HashMap<ScreenPublicId, ScreenId>,
    pub panes: HashMap<PanePublicId, PaneId>,
    pub tabs: HashMap<TabPublicId, SurfaceId>,
    /// Every view placement of a content resource. Terminal content may have
    /// any number of placements; browser content currently has one.
    pub content_placements: HashMap<ContentPublicId, Vec<SurfaceId>>,
    pub workspace_ids: HashMap<WorkspaceId, WorkspacePublicId>,
    pub screen_ids: HashMap<ScreenId, ScreenPublicId>,
    pub pane_ids: HashMap<PaneId, PanePublicId>,
    pub tab_ids: HashMap<SurfaceId, TabPublicId>,
    pub content_ids: HashMap<SurfaceId, ContentPublicId>,
    pub splits: HashMap<SplitPublicId, SplitId>,
    pub split_ids: HashMap<SplitId, SplitPublicId>,
    pub screen_workspace: HashMap<ScreenId, WorkspaceId>,
    pub pane_screen: HashMap<PaneId, ScreenId>,
    pub tab_pane: HashMap<SurfaceId, PaneId>,
}
