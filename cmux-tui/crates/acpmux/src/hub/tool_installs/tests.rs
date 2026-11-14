use super::*;
use serde_json::json;

#[test]
fn package_keys_pass_the_usage_patterns_key_rule() {
    for (manager, package, key) in [
        ("npm", "react", "npm:react"),
        ("npm", "@types/node", "npm:types/node"),
        ("pip", "ruamel-yaml", "pip:ruamel-yaml"),
        ("go", "golang.org/x/tools/gopls", "go:golang.org:x:tools:gopls"),
        ("apt", "libssl-dev", "apt:libssl-dev"),
    ] {
        let made = package_key(manager, package);
        assert_eq!(made, key);
        assert_eq!(cmux_usage_patterns::clean_key(&made), key, "{key} is kept as itself");
    }
}

#[test]
fn codex_argv_and_plain_commands() {
    assert_eq!(shell_command(Some(&json!("npm i zod"))).as_deref(), Some("npm i zod"));
    assert_eq!(
        shell_command(Some(&json!(["bash", "-lc", "npm i zod"]))).as_deref(),
        Some("npm i zod")
    );
    assert_eq!(shell_command(Some(&json!(["npm", "i", "zod"]))).as_deref(), Some("npm i zod"));
    assert_eq!(shell_command(Some(&json!({"x": 1}))), None);
    assert_eq!(shell_command(None), None);
}

#[test]
fn a_call_counts_once() {
    let key = "test-session\0call-once";
    assert!(first_sighting(key));
    assert!(!first_sighting(key));
}
