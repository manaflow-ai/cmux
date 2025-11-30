use std::path::PathBuf;

use crate::acp_client::provider::AcpProvider;

/// Get the cmux config directory (~/.cmux)
pub(crate) fn get_config_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(".cmux")
}

/// Load the last used ACP provider from config
pub fn load_last_provider() -> Option<AcpProvider> {
    let path = get_config_dir().join("last_acp_provider");
    if path.exists() {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|s| AcpProvider::from_short_name(s.trim()))
    } else {
        None
    }
}

/// Save the last used ACP provider to config
pub(crate) fn save_last_provider(provider: AcpProvider) {
    let dir = get_config_dir();
    if !dir.exists() {
        let _ = std::fs::create_dir_all(&dir);
    }
    let path = dir.join("last_acp_provider");
    let _ = std::fs::write(path, provider.short_name());
}

/// Load the last used model ID for a specific provider
pub(crate) fn load_last_model(provider: AcpProvider) -> Option<String> {
    let path = get_config_dir().join(format!("last_model_{}", provider.short_name()));
    if path.exists() {
        std::fs::read_to_string(path)
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    } else {
        None
    }
}

/// Save the last used model ID for a specific provider
pub(crate) fn save_last_model(provider: AcpProvider, model_id: &str) {
    let dir = get_config_dir();
    if !dir.exists() {
        let _ = std::fs::create_dir_all(&dir);
    }
    let path = dir.join(format!("last_model_{}", provider.short_name()));
    let _ = std::fs::write(path, model_id);
}
