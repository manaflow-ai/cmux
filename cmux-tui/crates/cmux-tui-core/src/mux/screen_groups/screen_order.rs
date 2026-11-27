//! Screen order normalization (moved out of screen_groups.rs, behavior unchanged).

use super::*;

/// Pinned screens first, then every group gathered at its first member. The
/// active screen stays active.
pub(crate) fn normalize_screen_order(workspace: &mut Workspace, screens: &ScreenPresentationState) {
    let active = workspace.screens.get(workspace.active_screen).map(|screen| screen.id);
    let group_of = |screen: &Screen| screens.members.get(screen.public_id.as_str()).cloned();
    let old = std::mem::take(&mut workspace.screens);
    let (mut ordered, rest): (Vec<Screen>, Vec<Screen>) =
        old.into_iter().partition(|screen| screens.is_pinned(screen.public_id.as_str()));
    let mut rest = rest.into_iter().map(Some).collect::<Vec<_>>();
    for index in 0..rest.len() {
        let Some(screen) = rest[index].take() else { continue };
        let group = group_of(&screen);
        ordered.push(screen);
        if let Some(group) = group {
            for later in rest.iter_mut().skip(index + 1) {
                if later
                    .as_ref()
                    .is_some_and(|candidate| group_of(candidate).as_ref() == Some(&group))
                {
                    ordered.extend(later.take());
                }
            }
        }
    }
    workspace.screens = ordered;
    let last = workspace.screens.len().saturating_sub(1);
    workspace.active_screen = active
        .and_then(|id| workspace.screens.iter().position(|screen| screen.id == id))
        .unwrap_or(0)
        .min(last);
}
