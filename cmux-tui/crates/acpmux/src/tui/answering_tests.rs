//! The TUI answer flow on a typed-number item (an MCP form's number field,
//! `claude_stdio/elicitation.rs`): the composer is that item's text, so a
//! digit is typed, never taken as an option shortcut.

use super::*;

fn number_item(options: Value) -> Value {
    json!({"harness": "claude", "agent": "deployer", "items": [{
        "id": "q0", "prompt": "Replicas", "input": "number", "options": options,
        "multiSelect": false, "allowsOther": true}]})
}

/// The app with `question` pending on the selected session and the
/// composer focused, and the requests it sends.
async fn asking(question: Value) -> (App, mpsc::UnboundedReceiver<Value>) {
    let (mut app, requests) = super::interaction_tests::app().await;
    let id = "test-session";
    app.sessions = vec![json!({"sessionId": id})];
    app.selected = app.drafts.len();
    let mut transcript = Transcript::default();
    transcript.items.push(Item::Permission {
        id: "p1".into(),
        title: "deployer".into(),
        options: vec![
            ("allow_once".into(), "Submit".into(), "allow_once".into()),
            ("reject_once".into(), "Decline".into(), "reject_once".into()),
        ],
        decided: None,
        question: Some(question),
    });
    app.transcripts.insert(id.into(), transcript);
    app.focus = Focus::Input;
    app.answer_permission(PermChoice::Allow);
    assert!(app.answering.is_some(), "the flow opens");
    (app, requests)
}

fn press(app: &mut App, keys: &str) {
    for c in keys.chars() {
        app.on_key(KeyEvent::new(KeyCode::Char(c), KeyModifiers::NONE));
    }
    app.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
}

/// The answers the flow sent, or None when it sent nothing.
async fn sent(requests: &mut mpsc::UnboundedReceiver<Value>) -> Option<Value> {
    loop {
        let msg = tokio::time::timeout(std::time::Duration::from_secs(2), requests.recv())
            .await
            .ok()??;
        if msg["method"] == method::MUX_PERMISSION_RESPOND {
            return Some(msg["params"]["answers"].clone());
        }
    }
}

#[tokio::test]
async fn a_required_number_takes_typed_digits() {
    let (mut app, mut requests) = asking(number_item(json!([]))).await;
    press(&mut app, "3");
    assert_eq!(sent(&mut requests).await, Some(json!({"Replicas": "3"})), "{}", app.status);
}

#[tokio::test]
async fn an_optional_number_takes_typed_1_not_its_first_option() {
    let options = json!([{"id": "No answer", "label": "No answer"}]);
    let (mut app, mut requests) = asking(number_item(options)).await;
    press(&mut app, "12");
    assert_eq!(sent(&mut requests).await, Some(json!({"Replicas": "12"})), "{}", app.status);
}

/// An item with no options (an MCP form's string field) takes typed text
/// from its first key: a leading digit is text, not an option shortcut.
#[tokio::test]
async fn a_free_text_item_takes_leading_digits() {
    let question = json!({"harness": "claude", "agent": "deployer", "items": [{
        "id": "q0", "prompt": "Note", "options": [], "multiSelect": false, "allowsOther": true}]});
    let (mut app, mut requests) = asking(question).await;
    press(&mut app, "123abc");
    assert_eq!(sent(&mut requests).await, Some(json!({"Note": "123abc"})), "{}", app.status);
}

/// Any other item keeps the digit shortcut.
#[tokio::test]
async fn a_digit_still_picks_an_option_elsewhere() {
    let question = json!({"harness": "claude", "agent": "Claude Code", "items": [{
        "id": "q0", "prompt": "Region", "multiSelect": false, "allowsOther": true,
        "options": [{"id": "US", "label": "US"}, {"id": "EU", "label": "EU"}]}]});
    let (mut app, mut requests) = asking(question).await;
    app.on_key(KeyEvent::new(KeyCode::Char('2'), KeyModifiers::NONE));
    assert_eq!(sent(&mut requests).await, Some(json!({"Region": "EU"})), "{}", app.status);
}
