use crate::models::EnvVar;

#[cfg(target_os = "macos")]
use std::process::Command;

#[cfg(target_os = "macos")]
const KEYCHAIN_SERVICE: &str = "cmux";
#[cfg(target_os = "macos")]
const KEYCHAIN_ACCOUNT: &str = "CLAUDE_CODE_OAUTH_TOKEN";

/// Get the Stack Auth project ID for credential storage
/// This ensures dev and prod credentials are stored separately
#[cfg(target_os = "macos")]
fn get_stack_project_id_for_storage() -> String {
    std::env::var("STACK_PROJECT_ID").unwrap_or_else(|_| {
        #[cfg(debug_assertions)]
        {
            // Dev Stack Auth project
            "1467bed0-8522-45ee-a8d8-055de324118c".to_string()
        }
        #[cfg(not(debug_assertions))]
        {
            // Prod Stack Auth project
            "8a877114-b905-47c5-8b64-3a2d90679577".to_string()
        }
    })
}

/// Get project-specific keychain account name for Stack refresh token
#[cfg(target_os = "macos")]
fn get_stack_refresh_account() -> String {
    format!("STACK_REFRESH_TOKEN_{}", get_stack_project_id_for_storage())
}

/// Store the Claude OAuth token in macOS Keychain using `security` CLI.
/// Uses -A flag to allow any application to access (no prompts).
#[cfg(target_os = "macos")]
pub fn store_claude_token(token: &str) -> Result<(), std::io::Error> {
    // First try to delete existing entry (ignore errors if it doesn't exist)
    let _ = Command::new("security")
        .args([
            "delete-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            KEYCHAIN_ACCOUNT,
        ])
        .output();

    // Add new entry with -A flag (allow any application, no prompts)
    let output = Command::new("security")
        .args([
            "add-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            KEYCHAIN_ACCOUNT,
            "-w",
            token,
            "-A", // Allow any application to access without warning
        ])
        .output()?;

    if !output.status.success() {
        return Err(std::io::Error::other(
            String::from_utf8_lossy(&output.stderr).to_string(),
        ));
    }
    Ok(())
}

/// Retrieve the Claude OAuth token from macOS Keychain using `security` CLI.
#[cfg(target_os = "macos")]
pub fn get_claude_token() -> Option<String> {
    let output = Command::new("security")
        .args([
            "find-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            KEYCHAIN_ACCOUNT,
            "-w", // Output only the password
        ])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let token = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if token.is_empty() {
        None
    } else {
        Some(token)
    }
}

/// Store token on Linux - use file-based storage as fallback
#[cfg(target_os = "linux")]
pub fn store_claude_token(token: &str) -> Result<(), std::io::Error> {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    let home = std::env::var("HOME")
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::NotFound, "HOME not set"))?;
    let path = std::path::PathBuf::from(home)
        .join(".cmux")
        .join("credentials.json");

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let content = serde_json::json!({ "claude_oauth_token": token }).to_string();
    fs::write(&path, &content)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

/// Retrieve token on Linux - use file-based storage as fallback
#[cfg(target_os = "linux")]
pub fn get_claude_token() -> Option<String> {
    use std::fs;

    let home = std::env::var("HOME").ok()?;
    let path = std::path::PathBuf::from(home)
        .join(".cmux")
        .join("credentials.json");
    let content = fs::read_to_string(&path).ok()?;
    let json: serde_json::Value = serde_json::from_str(&content).ok()?;
    json.get("claude_oauth_token")?.as_str().map(String::from)
}

/// Build the default environment variables to inject into sandboxes.
/// This includes the Claude OAuth token if available.
pub fn build_default_env_vars() -> Vec<EnvVar> {
    let mut env_vars = Vec::new();

    // Inject Claude OAuth token if available
    if let Some(token) = get_claude_token() {
        env_vars.push(EnvVar {
            key: "CLAUDE_CODE_OAUTH_TOKEN".to_string(),
            value: token,
        });
    }

    env_vars
}

/// Extract API key from output - looks for lines containing "sk-ant"
pub fn extract_api_key_from_output(output: &str) -> Option<String> {
    for line in output.lines() {
        let line = line.trim();
        // Look for the API key pattern - starts with sk-ant
        if let Some(start) = line.find("sk-ant") {
            // Extract from sk-ant to end of that token (no whitespace)
            let remaining = &line[start..];
            let end = remaining
                .find(|c: char| c.is_whitespace())
                .unwrap_or(remaining.len());
            let key = &remaining[..end];
            // Validate it looks like a real key (has reasonable length)
            if key.len() > 20 {
                return Some(key.to_string());
            }
        }
    }
    None
}

// =============================================================================
// Stack Auth Token Management
// =============================================================================

/// Store the Stack Auth refresh token in macOS Keychain using `security` CLI.
/// Uses project-specific account name to separate dev and prod credentials.
#[cfg(target_os = "macos")]
pub fn store_stack_refresh_token(token: &str) -> Result<(), std::io::Error> {
    let account = get_stack_refresh_account();

    // First try to delete existing entry (ignore errors if it doesn't exist)
    let _ = Command::new("security")
        .args([
            "delete-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            &account,
        ])
        .output();

    // Add new entry with -A flag (allow any application, no prompts)
    let output = Command::new("security")
        .args([
            "add-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            &account,
            "-w",
            token,
            "-A",
        ])
        .output()?;

    if !output.status.success() {
        return Err(std::io::Error::other(
            String::from_utf8_lossy(&output.stderr).to_string(),
        ));
    }
    Ok(())
}

/// Retrieve the Stack Auth refresh token from macOS Keychain using `security` CLI.
/// Uses project-specific account name to separate dev and prod credentials.
#[cfg(target_os = "macos")]
pub fn get_stack_refresh_token() -> Option<String> {
    let account = get_stack_refresh_account();

    let output = Command::new("security")
        .args([
            "find-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            &account,
            "-w",
        ])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let token = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if token.is_empty() {
        None
    } else {
        Some(token)
    }
}

/// Delete the Stack Auth refresh token from macOS Keychain.
/// Uses project-specific account name to separate dev and prod credentials.
#[cfg(target_os = "macos")]
pub fn delete_stack_refresh_token() -> Result<(), std::io::Error> {
    let account = get_stack_refresh_account();

    let output = Command::new("security")
        .args([
            "delete-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            &account,
        ])
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // "not found" is acceptable - means nothing to delete
        if !stderr.contains("could not be found") {
            return Err(std::io::Error::other(stderr.to_string()));
        }
    }
    Ok(())
}

/// Store Stack Auth refresh token on Linux - use file-based storage
#[cfg(target_os = "linux")]
pub fn store_stack_refresh_token(token: &str) -> Result<(), std::io::Error> {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    let home = std::env::var("HOME")
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::NotFound, "HOME not set"))?;
    let path = std::path::PathBuf::from(home)
        .join(".config")
        .join("cmux")
        .join("credentials.json");

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    // Read existing credentials or start fresh
    let mut creds: serde_json::Value = if path.exists() {
        let content = fs::read_to_string(&path)?;
        serde_json::from_str(&content).unwrap_or(serde_json::json!({}))
    } else {
        serde_json::json!({})
    };

    creds["stack_refresh_token"] = serde_json::json!(token);

    fs::write(&path, serde_json::to_string_pretty(&creds)?)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

/// Retrieve Stack Auth refresh token on Linux
#[cfg(target_os = "linux")]
pub fn get_stack_refresh_token() -> Option<String> {
    use std::fs;

    let home = std::env::var("HOME").ok()?;
    let path = std::path::PathBuf::from(home)
        .join(".config")
        .join("cmux")
        .join("credentials.json");
    let content = fs::read_to_string(&path).ok()?;
    let json: serde_json::Value = serde_json::from_str(&content).ok()?;
    json.get("stack_refresh_token")?.as_str().map(String::from)
}

/// Delete Stack Auth refresh token on Linux
#[cfg(target_os = "linux")]
pub fn delete_stack_refresh_token() -> Result<(), std::io::Error> {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    let home = std::env::var("HOME")
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::NotFound, "HOME not set"))?;
    let path = std::path::PathBuf::from(home)
        .join(".config")
        .join("cmux")
        .join("credentials.json");

    if !path.exists() {
        return Ok(());
    }

    let content = fs::read_to_string(&path)?;
    let mut creds: serde_json::Value =
        serde_json::from_str(&content).unwrap_or(serde_json::json!({}));

    if creds
        .as_object_mut()
        .map(|o| o.remove("stack_refresh_token"))
        .is_some()
    {
        fs::write(&path, serde_json::to_string_pretty(&creds)?)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

// =============================================================================
// Access Token Cache (in-memory with file-based persistence)
// =============================================================================

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use std::sync::OnceLock;
use std::sync::RwLock;

/// Cached access token with expiry
#[derive(Clone)]
pub struct CachedAccessToken {
    pub token: String,
    pub expires_at: i64, // Unix timestamp in seconds
}

/// Global cache for access token
static ACCESS_TOKEN_CACHE: OnceLock<RwLock<Option<CachedAccessToken>>> = OnceLock::new();

fn get_cache() -> &'static RwLock<Option<CachedAccessToken>> {
    ACCESS_TOKEN_CACHE.get_or_init(|| {
        // Try to load from file on first access
        RwLock::new(load_cached_access_token_from_file())
    })
}

/// Decode JWT payload to extract expiry time (without verification)
fn decode_jwt_expiry(token: &str) -> Option<i64> {
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() != 3 {
        return None;
    }

    let payload_b64 = parts[1];
    let payload_bytes = URL_SAFE_NO_PAD.decode(payload_b64).ok()?;
    let payload: serde_json::Value = serde_json::from_slice(&payload_bytes).ok()?;
    payload.get("exp")?.as_i64()
}

/// Get cached access token if it's still valid (with buffer time)
/// Returns None if no cached token or if it expires within `min_validity_secs`
pub fn get_cached_access_token(min_validity_secs: i64) -> Option<String> {
    let cache = get_cache();
    let guard = cache.read().ok()?;
    let cached = guard.as_ref()?;

    let now = chrono::Utc::now().timestamp();
    if cached.expires_at - now > min_validity_secs {
        Some(cached.token.clone())
    } else {
        None
    }
}

/// Cache a new access token
pub fn cache_access_token(token: &str) {
    if let Some(expires_at) = decode_jwt_expiry(token) {
        let cached = CachedAccessToken {
            token: token.to_string(),
            expires_at,
        };

        // Update in-memory cache
        if let Ok(mut guard) = get_cache().write() {
            *guard = Some(cached.clone());
        }

        // Persist to file (best effort)
        let _ = save_cached_access_token_to_file(&cached);
    }
}

/// Clear the cached access token
pub fn clear_cached_access_token() {
    if let Ok(mut guard) = get_cache().write() {
        *guard = None;
    }
    let _ = delete_cached_access_token_file();
}

/// Get the path to the access token cache file.
/// Uses separate cache files for dev and prod builds to prevent cross-contamination.
fn get_access_token_cache_path() -> Option<std::path::PathBuf> {
    let home = std::env::var("HOME").ok()?;
    // Use separate cache files for dev and prod to prevent using wrong project's token
    #[cfg(debug_assertions)]
    let cache_filename = "access_token_cache_dev.json";
    #[cfg(not(debug_assertions))]
    let cache_filename = "access_token_cache_prod.json";
    Some(
        std::path::PathBuf::from(home)
            .join(".config")
            .join("cmux")
            .join(cache_filename),
    )
}

/// Load cached access token from file
fn load_cached_access_token_from_file() -> Option<CachedAccessToken> {
    let path = get_access_token_cache_path()?;
    let content = std::fs::read_to_string(&path).ok()?;
    let json: serde_json::Value = serde_json::from_str(&content).ok()?;

    let token = json.get("token")?.as_str()?.to_string();
    let expires_at = json.get("expires_at")?.as_i64()?;

    // Check if still valid
    let now = chrono::Utc::now().timestamp();
    if expires_at > now {
        Some(CachedAccessToken { token, expires_at })
    } else {
        // Expired, clean up the file
        let _ = std::fs::remove_file(&path);
        None
    }
}

/// Save cached access token to file
fn save_cached_access_token_to_file(cached: &CachedAccessToken) -> std::io::Result<()> {
    let path = get_access_token_cache_path()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "HOME not set"))?;

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let json = serde_json::json!({
        "token": cached.token,
        "expires_at": cached.expires_at,
    });

    std::fs::write(&path, serde_json::to_string(&json)?)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }

    Ok(())
}

/// Delete the cached access token file
fn delete_cached_access_token_file() -> std::io::Result<()> {
    if let Some(path) = get_access_token_cache_path() {
        if path.exists() {
            std::fs::remove_file(&path)?;
        }
    }
    Ok(())
}

// =============================================================================
// Default Team Configuration
// =============================================================================

/// Get the path to the config file
fn get_config_path() -> Option<std::path::PathBuf> {
    let home = std::env::var("HOME").ok()?;
    // Use separate config files for dev and prod
    #[cfg(debug_assertions)]
    let config_filename = "config_dev.json";
    #[cfg(not(debug_assertions))]
    let config_filename = "config.json";
    Some(
        std::path::PathBuf::from(home)
            .join(".config")
            .join("cmux")
            .join(config_filename),
    )
}

/// Get the default team ID from config
pub fn get_default_team() -> Option<String> {
    let path = get_config_path()?;
    let content = std::fs::read_to_string(&path).ok()?;
    let json: serde_json::Value = serde_json::from_str(&content).ok()?;
    json.get("default_team")?.as_str().map(String::from)
}

/// Set the default team ID in config
pub fn set_default_team(team_id: &str) -> std::io::Result<()> {
    let path = get_config_path()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "HOME not set"))?;

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    // Read existing config or start fresh
    let mut config: serde_json::Value = if path.exists() {
        let content = std::fs::read_to_string(&path)?;
        serde_json::from_str(&content).unwrap_or(serde_json::json!({}))
    } else {
        serde_json::json!({})
    };

    config["default_team"] = serde_json::json!(team_id);

    std::fs::write(&path, serde_json::to_string_pretty(&config)?)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }

    Ok(())
}

/// Clear the default team from config
pub fn clear_default_team() -> std::io::Result<()> {
    let path = match get_config_path() {
        Some(p) => p,
        None => return Ok(()),
    };

    if !path.exists() {
        return Ok(());
    }

    let content = std::fs::read_to_string(&path)?;
    let mut config: serde_json::Value =
        serde_json::from_str(&content).unwrap_or(serde_json::json!({}));

    if let Some(obj) = config.as_object_mut() {
        obj.remove("default_team");
    }

    std::fs::write(&path, serde_json::to_string_pretty(&config)?)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }

    Ok(())
}
