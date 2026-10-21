//! Browser use thread (user, 2026-10-19): `--agent NAME` names the agent's
//! cursor, `drag SRC DST` and `upload SELECTOR FILE…` reach the app.

use serde_json::{Value, json};

use super::super::AppCommand;
use super::{agent_from_env, parse_page};

fn page(words: &[&str]) -> Result<(&'static str, Value), ()> {
    let args: Vec<String> = words.iter().map(|word| (*word).to_owned()).collect();
    match parse_page("tab_01ab", &args) {
        Ok(AppCommand::Call { method, params, .. }) => Ok((method, params)),
        _ => Err(()),
    }
}

#[test]
fn agent_flag_names_the_cursor_on_any_input_verb() {
    let (method, params) = page(&["click", "#go", "--agent", "Claude"]).unwrap();
    assert_eq!(method, "browser.page.click");
    assert_eq!(params["agent"], json!("Claude"));
    assert_eq!(params["selector"], json!("#go"));
    let (_, params) = page(&["fill", "--agent", "Codex", "#q", "hi"]).unwrap();
    assert_eq!(params["agent"], json!("Codex"));
    assert_eq!(params["text"], json!("hi"));
    let (_, params) = page(&["press", "Enter", "--agent", "Claude"]).unwrap();
    assert_eq!(params["agent"], json!("Claude"));
    assert!(page(&["click", "#go", "--agent"]).is_err(), "the flag needs a name");
}

#[test]
fn agent_name_defaults_from_the_environment() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |key: &str| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    };
    assert_eq!(agent_from_env(env(&[("CMUX_AGENT_NAME", "a139")])), Some("a139".into()));
    assert_eq!(agent_from_env(env(&[("CLAUDECODE", "1")])), Some("Claude".into()));
    assert_eq!(agent_from_env(env(&[("CODEX_SANDBOX", "seatbelt")])), Some("Codex".into()));
    assert_eq!(
        agent_from_env(env(&[("CLAUDECODE", "1"), ("CMUX_AGENT_NAME", "a1")])),
        Some("a1".into())
    );
    assert_eq!(agent_from_env(env(&[("CMUX_AGENT_NAME", "  ")])), None);
    assert_eq!(agent_from_env(env(&[])), None);
}

#[test]
fn drag_and_upload_reach_the_app() {
    let (method, params) = page(&["drag", "#card", "#done"]).unwrap();
    assert_eq!(method, "browser.page.drag");
    assert_eq!(params, json!({ "tab": "tab_01ab", "selector": "#card", "target": "#done" }));
    assert!(page(&["drag", "#card"]).is_err());
    let (method, params) = page(&["upload", "#file", "/tmp/a.txt", "/tmp/b.png"]).unwrap();
    assert_eq!(method, "browser.page.upload");
    assert_eq!(params["files"], json!(["/tmp/a.txt", "/tmp/b.png"]));
    assert!(page(&["upload", "#file"]).is_err(), "upload needs a file");
}
