//! Disabled provider switches in settings are not evidence of a Claude sign-in.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// Reads settings files only; starts no process.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::claude_auth;
use serde_json::json;
use std::collections::BTreeMap;

#[test]
fn claude_auth_settings_provider_switches_match_environment_truthiness() {
    let unique =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let home =
        std::env::temp_dir().join(format!("claude-auth-settings-{}-{unique}", std::process::id()));
    std::fs::create_dir(&home).unwrap();
    let env = BTreeMap::from([("CLAUDE_CONFIG_DIR".to_owned(), home.display().to_string())]);
    for key in ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
        for (value, configured) in [
            (json!(false), false),
            (json!(0), false),
            (json!("false"), false),
            (json!("FALSE"), false),
            (json!("0"), false),
            (json!(""), false),
            (json!(null), false),
            (json!(true), true),
            (json!(1), true),
            (json!("true"), true),
            (json!("1"), true),
        ] {
            std::fs::write(
                home.join("settings.json"),
                json!({"env": {key: value, "ANTHROPIC_API_KEY": "fixture-key"}}).to_string(),
            )
            .unwrap();
            let found = claude_auth::find(&env);
            // Match this fixture's source, independently of any managed host settings.
            let suffix = format!(" in {}", home.join("settings.json").display());
            assert_eq!(
                found.sources.contains(&format!("{key}{suffix}")),
                configured,
                "{key}={value}"
            );
            assert!(found.sources.contains(&format!("ANTHROPIC_API_KEY{suffix}")));
        }
    }
    std::fs::remove_dir_all(home).unwrap();
}
