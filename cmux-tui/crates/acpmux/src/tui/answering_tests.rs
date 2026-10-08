//! A pending agent question is answered through the answer flow, never by a
//! blank allow (plans/cmux-next/agent-questions.md).

use super::interaction_tests::app;
use super::*;

const SESSION: &str = "test-session";

fn key(c: char) -> KeyEvent {
    KeyEvent::new(KeyCode::Char(c), KeyModifiers::NONE)
}

fn code(c: KeyCode) -> KeyEvent {
    KeyEvent::new(c, KeyModifiers::NONE)
}

fn claude_question() -> Value {
    json!({"harness": "claude", "agent": "Claude Code", "items": [
        {"id": "q0", "header": "Auth", "prompt": "Which auth?", "multiSelect": false, "allowsOther": true,
         "options": [{"id": "OAuth", "label": "OAuth"}, {"id": "Keys", "label": "Keys"}]},
        {"id": "q1", "prompt": "Which checks?", "multiSelect": true, "allowsOther": true,
         "options": [{"id": "Lint", "label": "Lint"}, {"id": "Test", "label": "Test"}, {"id": "Docs", "label": "Docs"}]}]})
}

/// Selects one session whose transcript holds a pending permission, with
/// `question` in its `_meta.acpmux.question` unless it is null.
fn pending(app: &mut App, question: Value) {
    app.drafts.clear();
    app.sessions = vec![json!({"sessionId": SESSION, "harness": "claude", "cwd": "/tmp"})];
    app.selected = 0;
    let mut tool = json!({"title": "AskUserQuestion", "toolCallId": "t1"});
    if !question.is_null() {
        tool["_meta"] = json!({"acpmux": {"question": question}});
    }
    let mut t = Transcript::default();
    t.apply_event(&json!({"seq": 1, "dir": "mux", "kind": "permission_request", "msg": {
        "permissionId": "p1", "request": {"toolCall": tool, "options": [
            {"optionId": "allow_once", "name": "Allow", "kind": "allow_once"},
            {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"}]}}}));
    app.transcripts.insert(SESSION.into(), t);
    app.focus = Focus::Input;
}

/// Every request the app sent before a sentinel request it sends now.
async fn sent(app: &App, requests: &mut mpsc::UnboundedReceiver<Value>) -> Vec<Value> {
    app.request_bg("test/sentinel", json!({}), None);
    let mut out = vec![];
    loop {
        let msg = tokio::time::timeout(std::time::Duration::from_secs(5), requests.recv())
            .await
            .unwrap()
            .unwrap();
        if msg["method"] == "test/sentinel" {
            return out;
        }
        out.push(msg);
    }
}

fn responses(sent: &[Value]) -> Vec<Value> {
    sent.iter()
        .filter(|m| m["method"] == method::MUX_PERMISSION_RESPOND)
        .map(|m| m["params"].clone())
        .collect()
}

#[tokio::test]
async fn y_on_a_question_opens_the_answer_flow_and_sends_nothing() {
    let (mut app, mut requests) = app().await;
    pending(&mut app, claude_question());
    app.on_key(key('y'));
    assert!(app.answering.is_some(), "y opens the answer flow");
    // Every other allow entry point opens the flow too, and none answers.
    app.answering = None;
    app.run_action(Action::Allow, &[]);
    assert!(app.answering.is_some(), "Action::Allow opens the answer flow");
    app.answering = None;
    app.on_button(&ButtonAction::PermissionAllow);
    assert!(app.answering.is_some(), "the Allow button opens the answer flow");
    app.answering = None;
    app.on_key(key('1'));
    assert!(app.answering.is_some(), "a digit opens the answer flow");
    assert_eq!(app.answering.as_ref().map(|a| a.item), Some(0), "the digit does not pick yet");
    assert!(responses(&sent(&app, &mut requests).await).is_empty());
    // The card shows the active item.
    let mut terminal = ratatui::Terminal::new(ratatui::backend::TestBackend::new(120, 40)).unwrap();
    terminal.draw(|f| render::draw(f, &mut app)).unwrap();
    let screen: String =
        terminal.backend().buffer().content().iter().map(|cell| cell.symbol()).collect();
    assert!(screen.contains("Which auth?"), "the prompt is drawn");
    assert!(screen.contains("1. OAuth") && screen.contains("2. Keys"), "options are numbered");
}

#[tokio::test]
async fn picking_options_sends_the_answers_payload() {
    let (mut app, mut requests) = app().await;
    pending(&mut app, claude_question());
    app.on_key(key('y'));
    // Single select: the digit picks and advances.
    app.on_key(key('2'));
    assert_eq!(app.answering.as_ref().map(|a| a.item), Some(1));
    // Multi select: digits and Space toggle, Enter confirms the last item.
    app.on_key(key('1'));
    app.on_key(key('2'));
    app.on_key(key('2'));
    app.on_key(code(KeyCode::Down));
    app.on_key(key(' '));
    assert!(responses(&sent(&app, &mut requests).await).is_empty(), "nothing before Enter");
    app.on_key(code(KeyCode::Enter));
    assert!(app.answering.is_none());
    let replies = responses(&sent(&app, &mut requests).await);
    assert_eq!(
        replies,
        vec![json!({"sessionId": SESSION, "permissionId": "p1", "optionId": "allow_once",
            "answers": {"Which auth?": "Keys", "Which checks?": "Lint, Docs"}})]
    );
}

#[tokio::test]
async fn typed_text_becomes_the_other_answer() {
    let (mut app, mut requests) = app().await;
    pending(
        &mut app,
        json!({"harness": "codex", "agent": "Codex", "items": [
            {"id": "name", "prompt": "Name?", "options": [], "multiSelect": false, "allowsOther": true}]}),
    );
    app.on_key(key('y'));
    for c in "ledger 2".chars() {
        app.on_key(key(c));
    }
    app.on_key(code(KeyCode::Enter));
    let replies = responses(&sent(&app, &mut requests).await);
    assert_eq!(
        replies,
        vec![json!({"sessionId": SESSION, "permissionId": "p1", "optionId": "allow_once",
            "answers": {"name": {"answers": ["ledger 2"]}}})]
    );
    assert!(app.editor().is_empty(), "the Other text is consumed");
}

#[tokio::test]
async fn esc_leaves_the_flow_and_sends_nothing() {
    let (mut app, mut requests) = app().await;
    pending(&mut app, claude_question());
    app.on_key(key('y'));
    app.on_key(key('2'));
    app.on_key(key('x'));
    app.on_key(code(KeyCode::Esc));
    assert!(app.answering.is_none());
    assert!(responses(&sent(&app, &mut requests).await).is_empty());
    // The question is still pending, and n declines it.
    app.editor_mut().clear();
    app.on_key(key('n'));
    let replies = responses(&sent(&app, &mut requests).await);
    assert_eq!(
        replies,
        vec![json!({"sessionId": SESSION, "permissionId": "p1", "optionId": "reject_once"})]
    );
}

#[tokio::test]
async fn a_plain_permission_y_still_allows() {
    let (mut app, mut requests) = app().await;
    pending(&mut app, Value::Null);
    app.on_key(key('y'));
    assert!(app.answering.is_none());
    let replies = responses(&sent(&app, &mut requests).await);
    assert_eq!(
        replies,
        vec![json!({"sessionId": SESSION, "permissionId": "p1", "optionId": "allow_once"})]
    );
}
