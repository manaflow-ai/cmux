use std::path::Path;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::{Value, json};

use super::adapter::{Draft, DraftKind, Drafts, UiEvent, adapt};
use super::chat::Chat;
use super::editor::{Editor, EditorAction};
use super::link::{envelope, is_brain_socket, select_chief, send_params};
use super::pipe::finish_text;
use super::render::wrap;
use super::turn::TurnWatch;
use super::{Args, parse_args};

const CONV: &str = "conv_01J0000000000000000000000A";

fn strings(args: &[&str]) -> Vec<String> {
    args.iter().map(|a| (*a).to_owned()).collect()
}

fn message(seq: u64, author: &str, text: &str, key: &str) -> Value {
    json!({"id": format!("msg_{seq}"), "conversation": CONV, "seq": seq, "client_msg_id": key,
           "author": author, "parts": [{"type": "text", "text": text}],
           "created_at": "2026-10-08T21:04:05.000Z", "reactions": []})
}

fn item(message: Value) -> Value {
    json!({"type": "message", "conversation": CONV, "rev": 9, "message": message})
}

fn typing(on: bool) -> UiEvent {
    UiEvent::Typing { participant: "agent_mux".into(), on }
}

fn cursor(seq: u64) -> UiEvent {
    UiEvent::Cursor { participant: "agent_mux".into(), seq }
}

fn draft(seq: u64, text: &str, fresh: bool) -> Draft {
    Draft {
        participant: "agent_mux".into(),
        turn: "turn:optchat:7".into(),
        segment: 0,
        seq,
        kind: DraftKind::Talk,
        text: text.into(),
        fresh,
        done: false,
    }
}

fn key(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
    KeyEvent::new(code, modifiers)
}

#[test]
fn args_select_pipe_text_timeout_and_history() {
    assert_eq!(parse_args(&[]).unwrap(), Args { history: 20, ..Args::default() });
    let parsed = parse_args(&strings(&["-p", "hello", "--timeout=30", "--history", "5"])).unwrap();
    assert_eq!(parsed.prompt.as_deref(), Some("hello"));
    assert_eq!(parsed.timeout_secs, Some(30));
    assert_eq!(parsed.history, 5);
    assert!(parse_args(&strings(&["--help"])).unwrap().help);
    assert!(parse_args(&strings(&["-p"])).is_err());
    assert!(parse_args(&strings(&["--timeout", "soon"])).is_err());
    assert!(parse_args(&strings(&["--bogus"])).is_err());
    assert_eq!(parse_args(&strings(&["--history", "9000"])).unwrap().history, 500);
}

#[test]
fn chief_conversation_is_the_oldest_with_agent_mux() {
    let conv = |id: &str, created: &str, chief: bool| {
        let mut participants =
            vec![json!({"id": "user_local", "kind": "human", "display_name": "Me"})];
        if chief {
            participants.push(json!({"id": "agent_mux", "kind": "agent", "display_name": "mux", "agent_class": "mux"}));
        }
        json!({"id": id, "created_at": created, "participants": participants})
    };
    let list = vec![
        conv("conv_c", "2026-10-03T00:00:00.000Z", true),
        conv("conv_a", "2026-10-01T00:00:00.000Z", false),
        conv("conv_b", "2026-10-02T00:00:00.000Z", true),
        conv("conv_0", "2026-10-02T00:00:00.000Z", true),
    ];
    assert_eq!(select_chief(&list).unwrap()["id"], "conv_0");
    assert!(select_chief(&list[1..2]).is_none());
}

#[test]
fn a_brain_session_socket_is_refused() {
    assert!(is_brain_socket(Path::new("/Users/me/.cmux/brains/chief/daemon.sock")));
    assert!(!is_brain_socket(Path::new("/tmp/cmux-501/main.sock")));
    assert!(!is_brain_socket(Path::new("/Users/me/brains/.cmux/x.sock")));
}

#[test]
fn requests_are_v2_operations_on_the_current_session() {
    let line = envelope("chief-1", "conversation.send", send_params(CONV, "hi"), Some("cli-1"));
    assert_eq!(line["protocol"], "cmux.protocol/2");
    assert_eq!(line["type"], "request");
    assert_eq!(line["operation"], "conversation.send");
    assert_eq!(line["idempotency_key"], "cli-1");
    assert_eq!(
        line["params"],
        json!({"conversation": CONV, "text": "hi", "machine": "current", "session": "current"})
    );
    let read = envelope("chief-2", "conversation.list", json!({}), None);
    assert!(read.get("idempotency_key").is_none());
}

#[test]
fn adapter_reads_only_the_chief_conversation() {
    let line = item(message(4, "user_local", "hi", "k"));
    assert!(matches!(adapt(&line, CONV), Some(UiEvent::Message(m)) if m["seq"] == 4));
    assert_eq!(adapt(&line, "conv_other"), None);
    let typing_item =
        json!({"type": "typing", "conversation": CONV, "participant": "agent_mux", "on": true});
    assert_eq!(adapt(&typing_item, CONV), Some(typing(true)));
    let cursor_item = json!({"type": "read_cursor", "conversation": CONV, "rev": 3, "participant": "agent_mux", "seq": 4});
    assert_eq!(adapt(&cursor_item, CONV), Some(cursor(4)));
    let draft_item = json!({"type": "draft", "conversation": CONV, "participant": "agent_mux",
        "turn": "turn:optchat:7", "segment": 1, "seq": 1, "kind": "thought", "text": "hm", "fresh": true, "done": false});
    match adapt(&draft_item, CONV) {
        Some(UiEvent::Draft(d)) => {
            assert!(d.kind == DraftKind::Thought && d.fresh && d.text == "hm" && d.segment == 1);
        }
        other => panic!("{other:?}"),
    }
    let snapshot = json!({"type": "snapshot", "reset_reason": "initial", "conversation": {"id": CONV, "participants": []},
        "messages": [message(1, "user_local", "hi", "k")]});
    assert!(
        matches!(adapt(&snapshot, CONV), Some(UiEvent::Snapshot { messages, .. }) if messages.len() == 1)
    );
    assert_eq!(adapt(&json!({"type": "future_kind", "conversation": CONV}), CONV), None);
}

#[test]
fn drafts_append_in_order_and_wait_for_fresh_after_a_gap() {
    let mut drafts = Drafts::default();
    drafts.apply(&draft(1, "Hel", true));
    drafts.apply(&draft(2, "lo", false));
    assert_eq!(drafts.turns[0].talk(), "Hello");
    drafts.apply(&draft(4, " lost", false));
    drafts.apply(&draft(5, " more", false));
    assert_eq!(drafts.turns[0].talk(), "Hello", "a gap shows nothing new");
    drafts.apply(&draft(6, "Hello world", true));
    assert_eq!(drafts.turns[0].talk(), "Hello world", "a fresh resend replaces the segment");
    drafts.apply(&draft(7, "!", false));
    assert_eq!(drafts.turns[0].talk(), "Hello world!");
    drafts.apply(&Draft { segment: 1, ..draft(8, "Second part", true) });
    assert_eq!(
        drafts.turns[0].talk(),
        "Hello world!\n\nSecond part",
        "segment 1 follows segment 0"
    );
}

#[test]
fn drafts_end_with_the_posted_message_done_or_typing_off() {
    let mut drafts = Drafts::default();
    drafts.apply(&draft(1, "Hi", true));
    drafts.on_message(&message(9, "agent_mux", "Hi there", "turn:optchat:7"));
    assert!(drafts.is_empty());
    drafts.apply(&draft(1, "Hi", true));
    drafts.apply(&Draft { done: true, ..draft(2, "", false) });
    assert!(drafts.is_empty());
    drafts.apply(&draft(1, "Hi", true));
    drafts.on_typing_off("agent_mux");
    assert!(drafts.is_empty());
}

#[test]
fn the_answering_turn_is_the_one_after_the_cursor_reaches_the_message() {
    let mut watch = TurnWatch::new(10);
    // A turn already running stops for the new message: not the answer.
    watch.on(&typing(true));
    watch.on(&UiEvent::Message(message(9, "agent_mux", "old", "a")));
    watch.on(&typing(false));
    assert!(!watch.done);
    watch.on(&cursor(10));
    watch.on(&typing(true));
    assert!(watch.on(&UiEvent::Message(message(11, "agent_mux", "answer", "b"))).is_some());
    assert!(watch.on(&UiEvent::Message(message(12, "user_local", "from Home", "c"))).is_none());
    watch.on(&typing(false));
    assert!(watch.done);
    assert_eq!(watch.replies.len(), 1);
    assert_eq!(watch.replies[0]["seq"], 11);
}

#[test]
fn pipe_output_continues_the_streamed_draft() {
    assert_eq!(finish_text("", "Hello", false), "Hello");
    assert_eq!(finish_text("Hel", "Hello", true), "lo");
    assert_eq!(finish_text("Draft", "Final", true), "\nFinal");
    assert_eq!(finish_text("", "Second", true), "\nSecond");
}

#[test]
fn editor_sends_on_enter_and_adds_lines_with_alt_enter() {
    let mut editor = Editor::default();
    editor.insert("one");
    assert_eq!(editor.key(key(KeyCode::Enter, KeyModifiers::ALT)), EditorAction::None);
    editor.insert("two");
    assert_eq!(editor.cursor(), (1, 3));
    assert_eq!(
        editor.key(key(KeyCode::Enter, KeyModifiers::NONE)),
        EditorAction::Submit("one\ntwo".into())
    );
    assert_eq!(editor.text(), "");
    assert_eq!(editor.key(key(KeyCode::Enter, KeyModifiers::NONE)), EditorAction::None);
    assert_eq!(editor.key(key(KeyCode::Up, KeyModifiers::NONE)), EditorAction::None);
    assert_eq!(editor.text(), "one\ntwo", "Up recalls the sent message");
}

#[test]
fn editor_ctrl_keys_clear_stop_and_quit() {
    let mut editor = Editor::default();
    editor.insert("hello world");
    editor.key(key(KeyCode::Char('w'), KeyModifiers::CONTROL));
    assert_eq!(editor.text(), "hello ");
    assert_eq!(editor.key(key(KeyCode::Char('c'), KeyModifiers::CONTROL)), EditorAction::None);
    assert_eq!(editor.text(), "");
    assert_eq!(editor.key(key(KeyCode::Char('c'), KeyModifiers::CONTROL)), EditorAction::Interrupt);
    assert_eq!(editor.key(key(KeyCode::Char('d'), KeyModifiers::CONTROL)), EditorAction::Quit);
}

#[test]
fn chat_prints_each_message_once_and_reports_a_gap() {
    let mut chat = Chat::default();
    let lines = chat.message(&message(1, "user_local", "hi", "k"));
    assert!(lines.iter().any(|(_, l)| l.contains("hi")));
    assert!(chat.message(&message(1, "user_local", "hi", "k")).is_empty());
    let (_, gap) = chat.apply(&UiEvent::Message(message(5, "agent_mux", "late", "t")));
    assert_eq!(gap, Some(5));
}

#[test]
fn footer_shows_the_live_draft_status_and_input_cursor() {
    let mut chat = Chat::default();
    chat.apply(&typing(true));
    chat.apply(&UiEvent::Draft(draft(1, "Working on it", true)));
    let mut editor = Editor::default();
    editor.insert("ab");
    let (lines, (row, column)) = chat.footer(&editor, 40, 20);
    let text: Vec<&str> = lines.iter().map(|(_, l)| l.as_str()).collect();
    assert!(text[0].contains("Working on it"), "{text:?}");
    assert!(text.iter().any(|l| l.ends_with("› ab")), "{text:?}");
    assert_eq!(text[row], "› ab");
    assert_eq!(column, 4);
    chat.apply(&typing(false));
    let (lines, _) = chat.footer(&editor, 40, 20);
    assert!(!lines.iter().any(|(_, l)| l.contains("Working on it")));
}

#[test]
fn wrap_keeps_lines_and_breaks_at_spaces_by_width() {
    assert_eq!(wrap("one two three", 8), vec!["one two", "three"]);
    assert_eq!(wrap("a\nb", 8), vec!["a", "b"]);
    assert_eq!(wrap("日本語日本語", 8).len(), 2, "wide characters count two columns");
}
