//! Browser use thread (user, 2026-10-19): `--agent NAME` names the agent's
//! cursor, `drag SRC DST`, `upload SELECTOR FILE…` and `download …` reach the app.

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

#[test]
fn upload_takes_a_chooser_wait() {
    let (method, params) =
        page(&["upload", "#pick", "/tmp/a.txt", "--timeout-ms", "8000"]).unwrap();
    assert_eq!(method, "browser.page.upload");
    assert_eq!(params["files"], json!(["/tmp/a.txt"]));
    assert_eq!(params["timeout_ms"], json!(8000));
    assert!(page(&["upload", "#pick", "/tmp/a.txt", "--bogus"]).is_err());
    assert!(page(&["upload", "#pick", "/tmp/a.txt", "--timeout-ms", "soon"]).is_err());
}

#[test]
fn download_verbs_reach_the_app() {
    let (method, params) = page(&["download", "list", "--limit", "5"]).unwrap();
    assert_eq!(method, "browser.page.downloads");
    assert_eq!(params, json!({ "tab": "tab_01ab", "limit": 5 }));
    let (method, params) = page(&["download"]).unwrap();
    assert_eq!(method, "browser.page.download.wait");
    assert_eq!(params, json!({ "tab": "tab_01ab", "timeout_ms": 30000 }));
    let (method, params) =
        page(&["download", "wait", "--path", "/tmp/out.zip", "--timeout-ms", "90000"]).unwrap();
    assert_eq!(method, "browser.page.download.wait");
    assert_eq!(params["path"], json!("/tmp/out.zip"));
    assert_eq!(params["timeout_ms"], json!(90000));
    let (_, params) = page(&["downloads", "wait", "--id", "AB12"]).unwrap();
    assert_eq!(params["id"], json!("AB12"));
    assert!(page(&["download", "list", "--path", "/tmp/x"]).is_err());
    assert!(page(&["download", "wait", "--limit", "2"]).is_err());
    assert!(page(&["download", "later"]).is_err());
}

/// User, 2026-10-25: watch an agent's browser live from Home. `mirror` shows the tab in a
/// second pane too (default right of the Home chat); `--pane` names one, `--off` takes it out.
#[test]
fn mirror_shows_the_tab_in_a_second_pane() {
    let (method, params) = page(&["mirror"]).unwrap();
    assert_eq!(method, "browser.page.mirror");
    assert_eq!(params, json!({"tab": "tab_01ab"}));
    let (_, params) = page(&["mirror", "--pane", "pane_9"]).unwrap();
    assert_eq!(params["pane"], json!("pane_9"));
    let (_, params) = page(&["mirror", "--off"]).unwrap();
    assert_eq!(params["off"], json!(true));
    // Showing a tab drives nothing: no agent name rides along.
    let (_, params) = page(&["mirror", "--agent", "Claude"]).unwrap();
    assert!(params.get("agent").is_none());
    assert!(page(&["mirror", "extra"]).is_err());
}

/// cmux https://github.com/manaflow-ai/cmux/issues/25830: `fill-login [--submit]` asks the app to
/// fill the Secure Store login for the tab's site; no username or password ever rides in the
/// request.
#[test]
fn fill_login_asks_the_app_to_fill_the_saved_login() {
    let (method, params) = page(&["fill-login"]).unwrap();
    assert_eq!(method, "browser.page.fill_login");
    assert_eq!(params["tab"], json!("tab_01ab"));
    assert!(params.get("submit").is_none());
    let (method, params) = page(&["fill-login", "--submit", "--agent", "Chief"]).unwrap();
    assert_eq!(method, "browser.page.fill_login");
    assert_eq!(params["submit"], json!(true));
    assert_eq!(params["agent"], json!("Chief"));
    let keys: Vec<&String> = params.as_object().unwrap().keys().collect();
    assert_eq!(keys.len(), 3, "only tab, submit and agent: {keys:?}");
    let (method, _) = page(&["fill_login"]).unwrap();
    assert_eq!(method, "browser.page.fill_login");
    assert!(page(&["fill-login", "user@example.com"]).is_err(), "it takes no username");
    assert!(page(&["fill-login", "--password", "x"]).is_err(), "it takes no password");
    assert!(page(&["fill-login", "--sumbit"]).is_err());
}
