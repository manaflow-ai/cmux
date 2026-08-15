use super::{ActionAvailability, ActionContextSnapshot, DisabledReason};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PluginActionPermission {
    ReadContext,
    MutateTarget,
    OpenExternalUrl,
}

/// Typed invocation carried by future plugin manifests. The palette does not
/// write action names into the sidebar PTY. A later plugin host must validate
/// this identity, manifest revision, permission, and target before dispatch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PluginActionInvocation {
    pub plugin_id: String,
    pub action_id: String,
    pub manifest_revision: u64,
    pub permission: PluginActionPermission,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PluginActionContribution {
    pub plugin_id: String,
    pub action_id: String,
    pub manifest_revision: u64,
    pub title: String,
    pub subtitle: String,
    pub permission: PluginActionPermission,
    pub permission_granted: bool,
    pub runtime_available: bool,
    pub pane_focused: bool,
}

impl PluginActionContribution {
    pub(crate) fn invocation(&self) -> PluginActionInvocation {
        PluginActionInvocation {
            plugin_id: self.plugin_id.clone(),
            action_id: self.action_id.clone(),
            manifest_revision: self.manifest_revision,
            permission: self.permission,
        }
    }

    pub(crate) fn availability(
        &self,
        context: &ActionContextSnapshot,
    ) -> ActionAvailability {
        if !self.runtime_available {
            ActionAvailability::Disabled(DisabledReason::PluginUnavailable)
        } else if !self.permission_granted {
            ActionAvailability::Disabled(DisabledReason::PermissionDenied)
        } else if context.overlay.blocks_actions() {
            ActionAvailability::Disabled(DisabledReason::BlockedByOverlay)
        } else {
            ActionAvailability::Enabled
        }
    }

    pub(crate) fn focus_rank(&self, context: &ActionContextSnapshot) -> u16 {
        if self.pane_focused && matches!(context.focus, super::ActionFocus::Pane) { 90 } else { 20 }
    }
}

#[cfg(test)]
mod tests {
    use cmux_tui_core::SurfaceKind;

    use super::*;
    use crate::actions::{ActionFocus, ActionContextSnapshot};

    #[test]
    fn manifest_revision_permission_and_runtime_are_kept_typed() {
        let context =
            ActionContextSnapshot::for_test(ActionFocus::Pane, SurfaceKind::Pty);
        let mut contribution = PluginActionContribution {
            plugin_id: "git".to_string(),
            action_id: "open-pr".to_string(),
            manifest_revision: 7,
            title: "Open pull request".to_string(),
            subtitle: "Git".to_string(),
            permission: PluginActionPermission::OpenExternalUrl,
            permission_granted: false,
            runtime_available: true,
            pane_focused: true,
        };
        assert_eq!(
            contribution.availability(&context),
            ActionAvailability::Disabled(DisabledReason::PermissionDenied)
        );
        contribution.permission_granted = true;
        assert_eq!(contribution.availability(&context), ActionAvailability::Enabled);
        let invocation = contribution.invocation();
        assert_eq!(invocation.manifest_revision, 7);
        assert_eq!(invocation.permission, PluginActionPermission::OpenExternalUrl);

        let supported_permissions = [
            PluginActionPermission::ReadContext,
            PluginActionPermission::MutateTarget,
            PluginActionPermission::OpenExternalUrl,
        ];
        assert_eq!(supported_permissions.len(), 3);
    }
}
