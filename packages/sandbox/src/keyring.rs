use crate::models::EnvVar;

#[cfg(target_os = "macos")]
use std::process::Command;

#[cfg(target_os = "macos")]
const KEYCHAIN_SERVICE: &str = "cmux";
#[cfg(target_os = "macos")]
const KEYCHAIN_ACCOUNT: &str = "CLAUDE_CODE_OAUTH_TOKEN";

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
