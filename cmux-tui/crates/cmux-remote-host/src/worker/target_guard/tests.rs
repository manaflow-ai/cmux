//! The macOS `CuaTargetGuardTests`, case for case, with Linux executables:
//! pid 100 / window 9000 is a terminal (never allowed unless the owner lists
//! it), pid 102 / window 9001 is gedit.

use async_trait::async_trait;
use serde_json::{Value, json};

use super::{TargetResolver, check};
use crate::approval::Target;

struct Resolver;

fn terminal() -> Target {
    Target { bundle_id: None, executable: Some("/usr/bin/gnome-terminal".into()), name: "gnome-terminal".into() }
}

fn gedit() -> Target {
    Target { bundle_id: None, executable: Some("/usr/bin/gedit".into()), name: "gedit".into() }
}

#[async_trait]
impl TargetResolver for Resolver {
    async fn app_for_pid(&self, pid: u32) -> Option<Target> {
        match pid {
            100 => Some(terminal()),
            102 => Some(gedit()),
            _ => None,
        }
    }
    async fn app_for_window(&self, window_id: u32) -> Option<Target> {
        self.app_for_pid(match window_id {
            9000 => 100,
            9001 => 102,
            _ => 999,
        })
        .await
    }
    async fn app_named(&self, name: &str) -> Option<Target> {
        self.app_for_pid(match name {
            "Terminal" | "gnome-terminal" => 100,
            "gedit" => 102,
            _ => 999,
        })
        .await
    }
    async fn app_for_bundle_id(&self, _bundle_id: &str) -> Option<Target> {
        // Linux and Windows apps have no bundle ids.
        None
    }
}

async fn run(tool: &str, arguments: &str) -> Result<Vec<Target>, String> {
    let arguments: Value = serde_json::from_str(arguments).unwrap();
    check(tool, &arguments, &Resolver, &[]).await.map(|checked| checked.targets).map_err(|error| error.message)
}

async fn refused(tool: &str, arguments: &str) {
    assert!(run(tool, arguments).await.is_err(), "{tool} {arguments} must be refused");
}

async fn passes(tool: &str, arguments: &str) -> Vec<Target> {
    run(tool, arguments).await.unwrap_or_else(|error| panic!("{tool} {arguments} must pass: {error}"))
}

#[tokio::test]
async fn every_target_is_checked() {
    for arguments in [
        r#"{"pid":100}"#,
        r#"{"window_id":9000}"#,
        r#"{"pid":102,"window_id":9000}"#,
        r#"{"app_name":"Terminal"}"#,
        r#"{"bundle_id":"org.gnome.Terminal"}"#,
    ] {
        refused("click", arguments).await;
    }
}

#[tokio::test]
async fn a_refused_target_says_why() {
    let error = run("launch_app", r#"{"name":"Terminal"}"#).await.unwrap_err();
    assert!(error.contains("terminals"), "{error}");
}

#[tokio::test]
async fn untargeted_calls_pass() {
    for tool in ["list_apps", "get_screen_size", "check_permissions"] {
        assert!(passes(tool, "{}").await.is_empty());
    }
}

#[tokio::test]
async fn ordinary_targets_pass() {
    assert_eq!(passes("click", r#"{"pid":102,"window_id":9001}"#).await, vec![gedit()]);
    assert_eq!(passes("launch_app", r#"{"name":"gedit"}"#).await, vec![gedit()]);
}

#[tokio::test]
async fn unresolved_or_malformed_targets_fail_closed() {
    for arguments in [
        r#"{"pid":999}"#,
        r#"{"window_id":999}"#,
        r#"{"pid":true}"#,
        r#"{"pid":-1}"#,
        r#"{"pid":0}"#,
        r#"{"pid":4294967296}"#,
        r#"{"pid":"100"}"#,
        r#"{"pid":102.5}"#,
        r#"{"window_id":4294967296}"#,
        r#"{"window_id":true}"#,
        r#"{"bundle_id":"example.missing"}"#,
        r#"{"app_name":"Missing App"}"#,
        r#"{"app_name":""}"#,
    ] {
        refused("click", arguments).await;
    }
}

#[tokio::test]
async fn an_allowed_terminal_unlocks_only_itself() {
    let arguments = json!({"pid": 100});
    let allowed = check("click", &arguments, &Resolver, &["gnome-terminal".into()]).await;
    assert_eq!(allowed.unwrap().targets, vec![terminal()]);
}

#[tokio::test]
async fn desktop_input_cannot_bypass_target_checks() {
    refused("click", r#"{"scope":"desktop","x":10,"y":10}"#).await;
    refused("click", r#"{"scope":"desktop","pid":null,"window_id":null,"x":10,"y":10}"#).await;
}

#[tokio::test]
async fn desktop_observation_still_passes() {
    passes("get_desktop_state", r#"{"scope":"desktop"}"#).await;
}

#[tokio::test]
async fn tools_that_hide_their_targets_are_refused() {
    let error = run("run_script", r#"{"script":"cua.click({pid:100,x:1,y:1})"}"#).await.unwrap_err();
    assert!(error.contains("run_script"), "{error}");
    refused("replay_trajectory", r#"{"dir":"/tmp/recording"}"#).await;
}

#[tokio::test]
async fn every_batch_target_is_checked() {
    for arguments in [
        r#"{"pid":100,"steps":[{"tool":"click","args":{"x":1,"y":1}}]}"#,
        r#"{"steps":[{"tool":"click","args":{"pid":100,"x":1,"y":1}}]}"#,
        r#"{"steps":[{"click":{"window_id":9000,"x":1,"y":1}}]}"#,
        r#"{"pid":102,"steps":[{"tool":"click","args":{"x":1,"y":1}}],"observe":{"pid":100}}"#,
        r#"{"steps":[{"tool":"click","args":{"app":"Calculator","role":"button","name":"7"}}]}"#,
        r#"{"app":"gedit","steps":[{"tool":"press_key","args":{"key":"a"}}]}"#,
        r#"{"pid":102,"steps":[{"tool":"click","args":{"window":"Terminal","x":1,"y":1}}]}"#,
        r#"{"steps":[{"tool":"click","args":{"element_token":"s00000001:3"}}]}"#,
        r#"{"steps":[{"tool":"click","args":{"scope":"desktop","x":1,"y":1}}]}"#,
        r#"{"steps":[{"tool":"type_text","args":{"app_name":"Terminal","text":"ls"}}]}"#,
    ] {
        for tool in ["run_steps", "run_actions"] {
            refused(tool, arguments).await;
        }
    }
}

#[tokio::test]
async fn a_batch_with_checked_windows_passes() {
    let arguments = r#"{"pid":102,"window_id":9001,"steps":[{"tool":"click","args":{"element_token":"s00000001:3","pid":102}},{"type_text":{"text":"hi"},"expect":[{"role":"button","name":"Save"}]}],"observe":{}}"#;
    assert_eq!(passes("run_steps", arguments).await, vec![gedit()]);
}

#[tokio::test]
async fn batch_steps_inherit_the_top_level_target() {
    for tool in ["run_steps", "run_actions"] {
        for step in [r#"{"tool":"click","args":{"element_token":"s00000001:3"}}"#, r#"{"click":{"element_token":"s00000001:3"}}"#] {
            passes(tool, &format!(r#"{{"pid":102,"window_id":9001,"steps":[{step}]}}"#)).await;
        }
    }
}

#[tokio::test]
async fn blocked_batch_defaults_and_step_overrides_are_refused() {
    for tool in ["run_steps", "run_actions"] {
        for arguments in [
            r#"{"pid":100,"window_id":9000,"steps":[{"tool":"click","args":{"element_token":"s00000001:3"}}]}"#,
            r#"{"pid":102,"window_id":9000,"steps":[{"click":{"element_token":"s00000001:3"}}]}"#,
            r#"{"pid":102,"window_id":9001,"steps":[{"tool":"click","args":{"pid":100,"element_token":"s00000001:3"}}]}"#,
            r#"{"pid":102,"window_id":9001,"steps":[{"click":{"pid":100,"element_token":"s00000001:3"}}]}"#,
        ] {
            refused(tool, arguments).await;
        }
    }
}

#[tokio::test]
async fn explicit_batch_targets_do_not_borrow_the_default_pid() {
    for tool in ["run_steps", "run_actions"] {
        for target in [r#""window_id":9001"#, r#""target":{"kind":"desktop","display_id":"primary"}"#] {
            let arguments =
                format!(r#"{{"pid":102,"window_id":9001,"steps":[{{"click":{{{target},"element_token":"s00000001:3"}}}}]}}"#);
            refused(tool, &arguments).await;
        }
    }
}

#[tokio::test]
async fn an_element_token_needs_its_pid() {
    refused("set_value", r#"{"element_token":"s00000001:3","value":"x"}"#).await;
    passes("set_value", r#"{"element_token":"s00000001:3","pid":102,"value":"x"}"#).await;
}

#[tokio::test]
async fn nested_and_alias_targets_cannot_bypass_policy() {
    for arguments in [
        r#"{"target":{"kind":"window","pid":100,"window_id":9001}}"#,
        r#"{"target":{"kind":"window","pid":102,"window_id":9000}}"#,
        r#"{"target":{"kind":"app","pid":100}}"#,
        r#"{"target":{"kind":"application","bundle_id":"org.gnome.Terminal"}}"#,
        r#"{"app_bundle_id":"org.gnome.Terminal"}"#,
        r#"{"target":{"kind":"window","pid":102,"window_id":9001},"bundle_id":"org.gnome.Terminal"}"#,
    ] {
        refused("press_key", arguments).await;
    }
}

#[tokio::test]
async fn typed_desktop_input_is_refused() {
    for tool in ["move_cursor", "click", "drag", "scroll", "type_text", "press_key", "hotkey", "type_text_chars"] {
        refused(tool, r#"{"target":{"kind":"desktop","display_id":"primary"},"key":"Return"}"#).await;
    }
}

#[tokio::test]
async fn unknown_target_shapes_are_refused() {
    for arguments in [
        r#"{"target":null}"#,
        r#"{"target":"desktop"}"#,
        r#"{"target":[]}"#,
        r#"{"target":{}}"#,
        r#"{"target":{"kind":"future","pid":102}}"#,
        r#"{"target":{"kind":"window","pid":102}}"#,
        r#"{"target":{"kind":"window","pid":102,"window_id":9001,"app":"Terminal"}}"#,
        r#"{"target":{"kind":"window","pid":true,"window_id":9001}}"#,
        r#"{"target":{"kind":"window","pid":102,"window_id":4294967296}}"#,
        r#"{"target":{"kind":"window","pid":102,"window_id":9001},"pid":102}"#,
        r#"{"target":{"kind":"window","pid":102,"window_id":9001},"scope":"window"}"#,
        r#"{"scope":"future","pid":102}"#,
        r#"{"app":"Terminal"}"#,
        r#"{"window":"Terminal"}"#,
    ] {
        let error = run("click", arguments).await.expect_err(arguments);
        assert!(error.contains("target"), "{arguments}: {error}");
    }
}

#[tokio::test]
async fn typed_targets_are_refused_for_unsupported_tools() {
    refused("list_apps", r#"{"target":{"kind":"window","pid":102,"window_id":9001}}"#).await;
}

#[tokio::test]
async fn a_typed_safe_window_passes() {
    for tool in ["click", "type_text_chars"] {
        assert_eq!(passes(tool, r#"{"target":{"kind":"window","pid":102,"window_id":9001}}"#).await, vec![gedit()]);
    }
}

#[tokio::test]
async fn batches_check_typed_targets_and_hidden_dispatch() {
    for tool in ["run_steps", "run_actions"] {
        for arguments in [
            r#"{"steps":[{"press_key":{"target":{"kind":"desktop","display_id":"primary"},"key":"Return"}}]}"#,
            r#"{"steps":[{"tool":"click","args":{"target":{"kind":"window","pid":102,"window_id":9000}}}]}"#,
            r#"{"steps":[{"tool":"replay_trajectory","args":{"dir":"/tmp/recording"}}]}"#,
            r#"{"steps":[{"run_script":{"script":"cua.press_key({key:'Return'})"}}]}"#,
        ] {
            refused(tool, arguments).await;
        }
    }
}
