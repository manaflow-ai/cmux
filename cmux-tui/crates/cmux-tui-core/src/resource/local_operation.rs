//! The app-local operations (moved out of resource.rs, unchanged).

use serde::{Deserialize, Serialize};

use super::OperationClass;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum LocalOperation {
    #[serde(rename = "sidebar_plugin.list")]
    SidebarPluginList,
    #[serde(rename = "sidebar_plugin.install")]
    SidebarPluginInstall,
    #[serde(rename = "sidebar_plugin.use")]
    SidebarPluginUse,
    #[serde(rename = "sidebar_plugin.update")]
    SidebarPluginUpdate,
    #[serde(rename = "sidebar_plugin.remove")]
    SidebarPluginRemove,
    #[serde(rename = "sidebar_plugin.use_builtin")]
    SidebarPluginUseBuiltin,
}

impl LocalOperation {
    pub const fn class(self) -> OperationClass {
        OperationClass::Local
    }
}
