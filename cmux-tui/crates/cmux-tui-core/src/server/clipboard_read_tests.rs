//! Daemon clipboard-read broker: the frontend user path subscribes and
//! answers, every other read is refused at once, and a host cancel withdraws
//! the question.

use std::sync::mpsc;
use std::time::{Duration, Instant};

use ghostty_vt::{ClipboardLocation, MAX_CLIPBOARD_READ_BYTES};
use serde_json::{Value, json};

use super::super::origin_gate::{set_role_for_test, set_verified_app_for_test};
use super::super::responses::response_error_code;
use super::super::tests::captured_writer;
use super::super::{
    BoundedOutbound, ClientTransport, Command, MessageWriter, advertised_capabilities,
    disconnect_client, handle_command,
};
use super::{CAPABILITY, HostRead, HostSignal};
use crate::terminal_host_protocol::{
    Frame, MAX_FRAME_PAYLOAD, MessageKind, read_frame, write_frame,
};
use crate::{Mux, SurfaceId, SurfaceOptions};

const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";
const OTHER_TERMINAL: &str = "term_fedcba9876543210fedcba9876543210";

struct Client {
    id: u64,
    writer: MessageWriter,
    outbound: std::sync::Arc<BoundedOutbound>,
}

fn command(value: Value) -> Command {
    serde_json::from_value(value).expect("raw command")
}

fn connect(mux: &std::sync::Arc<Mux>, kind: &str) -> Client {
    let (writer, outbound) = captured_writer();
    let id = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.control_clients.set_info(id, None, Some(kind.to_string()), None).unwrap();
    Client { id, writer, outbound }
}

/// The verified cmux app's frontend connection.
fn frontend(mux: &std::sync::Arc<Mux>) -> Client {
    let client = connect(mux, "frontend");
    set_role_for_test(mux, client.id, "main");
    set_verified_app_for_test(mux, client.id, true);
    client
}

fn run(mux: &std::sync::Arc<Mux>, client: &Client, value: Value) -> anyhow::Result<Value> {
    handle_command(mux, client.id, command(value), &client.writer)
}

fn subscribe(mux: &std::sync::Arc<Mux>, client: &Client, terminals: &[&str]) {
    let reply =
        run(mux, client, json!({"cmd": "terminal-clipboard-subscribe", "terminal_ids": terminals}))
            .unwrap();
    assert_eq!(reply, json!({"clipboard_read_ready": true}));
}

fn reply(mux: &std::sync::Arc<Mux>, client: &Client, request_id: &str, text: Value) -> Value {
    run(
        mux,
        client,
        json!({"cmd": "terminal-clipboard-reply", "request_id": request_id, "text": text}),
    )
    .unwrap()
}

/// A host read whose answer arrives on the returned channel.
fn fake_read(
    surface: SurfaceId,
    token: u64,
    terminal: &str,
) -> (HostRead, mpsc::Receiver<Option<Vec<u8>>>) {
    let (sender, answers) = mpsc::channel();
    let read = HostRead {
        surface,
        terminal: Some(terminal.to_string()),
        token,
        location: ClipboardLocation::Standard,
        complete: Box::new(move |text| sender.send(text).is_ok()),
    };
    (read, answers)
}

fn ask(
    mux: &Mux,
    surface: SurfaceId,
    token: u64,
    terminal: &str,
) -> mpsc::Receiver<Option<Vec<u8>>> {
    let (read, answers) = fake_read(surface, token, terminal);
    mux.control_clients.clipboard_reads.handle(HostSignal::Request(read));
    answers
}

fn next_event(outbound: &BoundedOutbound) -> Value {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if let Some(message) = outbound.try_pop() {
            return serde_json::from_str(&message).expect("outbound JSON");
        }
        assert!(Instant::now() < deadline, "no control event arrived");
        std::thread::sleep(Duration::from_millis(1));
    }
}

fn assert_no_event(outbound: &BoundedOutbound) {
    assert_eq!(outbound.try_pop(), None, "unexpected control event");
}

fn read_event(outbound: &BoundedOutbound) -> String {
    let event = next_event(outbound);
    assert_eq!(event["event"], "terminal-clipboard-read", "{event}");
    event["request_id"].as_str().unwrap().to_string()
}

fn refused_at_once(answers: &mpsc::Receiver<Option<Vec<u8>>>) {
    assert_eq!(answers.try_recv(), Ok(None), "the read must be refused at once");
}

fn mux() -> std::sync::Arc<Mux> {
    Mux::new_for_test("clipboard-broker", SurfaceOptions::default())
}

#[test]
fn the_capability_is_advertised() {
    assert!(advertised_capabilities(false).contains(&CAPABILITY));
}

/// End to end through a hosted surface: the host's request reaches only the
/// subscribed frontend, and its reply goes back to the host once.
#[test]
fn a_granted_reply_reaches_the_host_through_the_hosted_surface() {
    let mux = mux();
    let frontend = frontend(&mux);
    subscribe(&mux, &frontend, &[TERMINAL]);
    let terminal = crate::resource::TerminalPublicId::parse(TERMINAL.to_string()).unwrap();
    let (_surface, mut host) = crate::surface::hosted_surface_for_clipboard_test(&mux, terminal);
    let mut payload = 7u64.to_le_bytes().to_vec();
    payload.push(2);
    write_frame(&mut host, &Frame::new(MessageKind::ClipboardReadRequest, payload)).unwrap();

    let event = next_event(&frontend.outbound);
    assert_eq!(event["event"], "terminal-clipboard-read");
    assert_eq!(event["terminal_id"], TERMINAL);
    assert_eq!(event["location"], "primary");
    assert_eq!(event["host"], json!({"kind": "local"}));
    let request_id = event["request_id"].as_str().unwrap().to_string();
    assert_eq!(request_id.len(), 36, "a UUID request id: {request_id}");

    assert_eq!(
        reply(&mux, &frontend, &request_id, json!("hi")),
        json!({"accepted": true, "granted": true})
    );
    let reply_frame = loop {
        let frame = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
        if frame.kind == MessageKind::ClipboardReadReply {
            break frame;
        }
    };
    let mut expected = 7u64.to_le_bytes().to_vec();
    expected.extend_from_slice(&[1, 2, 0, 0, 0, b'h', b'i']);
    assert_eq!(reply_frame.payload, expected);
    assert_eq!(
        reply(&mux, &frontend, &request_id, json!("again")),
        json!({"accepted": false, "granted": false}),
        "a read is answered once"
    );
}

#[test]
fn a_refusal_answers_an_empty_clipboard() {
    let mux = mux();
    let frontend = frontend(&mux);
    subscribe(&mux, &frontend, &[TERMINAL]);
    let answers = ask(&mux, 1, 7, TERMINAL);
    let request_id = read_event(&frontend.outbound);
    assert_eq!(
        reply(&mux, &frontend, &request_id, Value::Null),
        json!({"accepted": true, "granted": false})
    );
    assert_eq!(answers.try_recv(), Ok(None));

    let answers = ask(&mux, 1, 8, TERMINAL);
    let request_id = read_event(&frontend.outbound);
    let refused =
        run(&mux, &frontend, json!({"cmd": "terminal-clipboard-reply", "request_id": request_id}))
            .unwrap();
    assert_eq!(refused, json!({"accepted": true, "granted": false}), "absent text refuses");
    assert_eq!(answers.try_recv(), Ok(None));
}

#[test]
fn zero_or_several_subscribers_refuse_at_once() {
    let mux = mux();
    refused_at_once(&ask(&mux, 1, 7, TERMINAL));

    let first = frontend(&mux);
    let second = frontend(&mux);
    subscribe(&mux, &first, &[TERMINAL]);
    subscribe(&mux, &second, &[TERMINAL]);
    refused_at_once(&ask(&mux, 1, 8, TERMINAL));
    assert_no_event(&first.outbound);
    assert_no_event(&second.outbound);
}

/// Agents, page relays, unverified main connections and non-frontend kinds
/// can neither subscribe nor answer.
#[test]
fn only_the_frontend_user_path_may_subscribe_or_reply() {
    let mux = mux();
    let agent = connect(&mux, "frontend");
    let page = connect(&mux, "frontend");
    set_role_for_test(&mux, page.id, "page_relay");
    let unverified = connect(&mux, "frontend");
    set_role_for_test(&mux, unverified.id, "main");
    let not_frontend = connect(&mux, "cli");
    set_role_for_test(&mux, not_frontend.id, "main");
    set_verified_app_for_test(&mux, not_frontend.id, true);
    for client in [&agent, &page, &unverified, &not_frontend] {
        let error = run(
            &mux,
            client,
            json!({"cmd": "terminal-clipboard-subscribe", "terminal_ids": [TERMINAL]}),
        )
        .unwrap_err();
        assert_eq!(response_error_code(&error).as_deref(), Some("origin.forbidden"));
    }
    refused_at_once(&ask(&mux, 1, 7, TERMINAL));

    let frontend = frontend(&mux);
    subscribe(&mux, &frontend, &[TERMINAL]);
    let answers = ask(&mux, 1, 8, TERMINAL);
    let request_id = read_event(&frontend.outbound);
    for client in [&agent, &page, &unverified, &not_frontend] {
        let error = run(
            &mux,
            client,
            json!({"cmd": "terminal-clipboard-reply", "request_id": request_id, "text": "x"}),
        )
        .unwrap_err();
        assert_eq!(response_error_code(&error).as_deref(), Some("origin.forbidden"));
    }
    assert!(answers.try_recv().is_err(), "a forbidden reply changes nothing");
    assert_eq!(
        reply(&mux, &frontend, &request_id, json!("ok")),
        json!({"accepted": true, "granted": true})
    );
    assert_eq!(answers.try_recv(), Ok(Some(b"ok".to_vec())));
}

#[test]
fn another_frontend_cannot_answer_someone_elses_read() {
    let mux = mux();
    let asked = frontend(&mux);
    let other = frontend(&mux);
    subscribe(&mux, &asked, &[TERMINAL]);
    subscribe(&mux, &other, &[OTHER_TERMINAL]);
    let answers = ask(&mux, 1, 7, TERMINAL);
    let request_id = read_event(&asked.outbound);
    assert_eq!(
        reply(&mux, &other, &request_id, json!("stolen")),
        json!({"accepted": false, "granted": false})
    );
    assert!(answers.try_recv().is_err());
    assert_eq!(
        reply(&mux, &asked, &request_id, json!("mine")),
        json!({"accepted": true, "granted": true})
    );
    assert_eq!(answers.try_recv(), Ok(Some(b"mine".to_vec())));
    assert_eq!(
        reply(&mux, &asked, "00000000-0000-4000-8000-000000000000", json!("x")),
        json!({"accepted": false, "granted": false}),
        "unknown request ids are not accepted"
    );
}

#[test]
fn text_over_one_mebibyte_is_refused() {
    let mux = mux();
    let frontend = frontend(&mux);
    subscribe(&mux, &frontend, &[TERMINAL]);
    let answers = ask(&mux, 1, 7, TERMINAL);
    let request_id = read_event(&frontend.outbound);
    let oversized = "x".repeat(MAX_CLIPBOARD_READ_BYTES + 1);
    assert_eq!(
        reply(&mux, &frontend, &request_id, json!(oversized)),
        json!({"accepted": true, "granted": false})
    );
    assert_eq!(answers.try_recv(), Ok(None));
}

#[test]
fn a_second_read_on_an_open_terminal_is_refused_at_once() {
    let mux = mux();
    let frontend = frontend(&mux);
    subscribe(&mux, &frontend, &[TERMINAL]);
    let first = ask(&mux, 1, 7, TERMINAL);
    let request_id = read_event(&frontend.outbound);
    refused_at_once(&ask(&mux, 2, 9, TERMINAL));
    assert_no_event(&frontend.outbound);
    assert_eq!(
        reply(&mux, &frontend, &request_id, json!("hi")),
        json!({"accepted": true, "granted": true})
    );
    assert_eq!(first.try_recv(), Ok(Some(b"hi".to_vec())));
}

/// The host keeps one read per terminal open, so a new token from the same
/// surface means the older read is over: it is withdrawn, not blocking.
#[test]
fn a_newer_read_from_the_same_surface_withdraws_the_older_one() {
    let mux = mux();
    let frontend = frontend(&mux);
    subscribe(&mux, &frontend, &[TERMINAL]);
    let older = ask(&mux, 1, 7, TERMINAL);
    let older_id = read_event(&frontend.outbound);
    let newer = ask(&mux, 1, 8, TERMINAL);
    assert_eq!(
        next_event(&frontend.outbound),
        json!({"event": "terminal-clipboard-read-cancelled", "request_id": older_id})
    );
    let newer_id = read_event(&frontend.outbound);
    assert!(older.try_recv().is_err(), "the host already resolved the older read");
    assert_eq!(
        reply(&mux, &frontend, &older_id, json!("x")),
        json!({"accepted": false, "granted": false})
    );
    assert_eq!(
        reply(&mux, &frontend, &newer_id, json!("y")),
        json!({"accepted": true, "granted": true})
    );
    assert_eq!(newer.try_recv(), Ok(Some(b"y".to_vec())));
}

#[test]
fn a_frontend_holds_at_most_sixteen_open_reads() {
    let mux = mux();
    let frontend = frontend(&mux);
    let terminals: Vec<String> = (0..17).map(|index| format!("term_{index:032x}")).collect();
    let names: Vec<&str> = terminals.iter().map(String::as_str).collect();
    subscribe(&mux, &frontend, &names);
    let mut open = Vec::new();
    for (index, terminal) in names.iter().take(16).enumerate() {
        open.push(ask(&mux, index as u64 + 1, 1, terminal));
        read_event(&frontend.outbound);
    }
    refused_at_once(&ask(&mux, 99, 1, names[16]));
    assert_no_event(&frontend.outbound);
    assert!(open.iter().all(|answers| answers.try_recv().is_err()));
}

#[test]
fn frontend_disconnect_refuses_its_open_reads() {
    let mux = mux();
    let frontend = frontend(&mux);
    subscribe(&mux, &frontend, &[TERMINAL, OTHER_TERMINAL]);
    let first = ask(&mux, 1, 7, TERMINAL);
    let second = ask(&mux, 2, 7, OTHER_TERMINAL);
    read_event(&frontend.outbound);
    read_event(&frontend.outbound);
    disconnect_client(&mux, frontend.id, false);
    assert_eq!(first.try_recv(), Ok(None));
    assert_eq!(second.try_recv(), Ok(None));
    refused_at_once(&ask(&mux, 1, 8, TERMINAL));
}

#[test]
fn a_host_cancel_withdraws_the_read_from_its_frontend() {
    let mux = mux();
    let frontend = frontend(&mux);
    subscribe(&mux, &frontend, &[TERMINAL]);
    let answers = ask(&mux, 1, 7, TERMINAL);
    let request_id = read_event(&frontend.outbound);
    let broker = &mux.control_clients.clipboard_reads;
    broker.handle(HostSignal::Cancel { surface: 2, token: 7 });
    broker.handle(HostSignal::Cancel { surface: 1, token: 8 });
    assert_no_event(&frontend.outbound);
    broker.handle(HostSignal::Cancel { surface: 1, token: 7 });
    assert_eq!(
        next_event(&frontend.outbound),
        json!({"event": "terminal-clipboard-read-cancelled", "request_id": request_id})
    );
    assert_eq!(
        reply(&mux, &frontend, &request_id, json!("late")),
        json!({"accepted": false, "granted": false})
    );
    assert!(answers.try_recv().is_err(), "the host already refused it");
}

#[test]
fn subscriptions_are_capped_at_sixteen_frontends_and_256_terminals() {
    let crowded = mux();
    let frontends: Vec<Client> = (0..17).map(|_| frontend(&crowded)).collect();
    for client in &frontends[..16] {
        subscribe(&crowded, client, &[TERMINAL]);
    }
    let subscribe_cmd = json!({"cmd": "terminal-clipboard-subscribe", "terminal_ids": [TERMINAL]});
    assert!(run(&crowded, &frontends[16], subscribe_cmd).is_err(), "a 17th frontend");
    // A subscribed frontend may still replace its own subscription.
    subscribe(&crowded, &frontends[0], &[OTHER_TERMINAL]);

    let mux = mux();
    let client = frontend(&mux);
    let terminals: Vec<String> = (0..257).map(|index| format!("term_{index:032x}")).collect();
    let too_many = json!({"cmd": "terminal-clipboard-subscribe", "terminal_ids": &terminals});
    assert!(run(&mux, &client, too_many).is_err(), "257 terminal ids");
    subscribe(&mux, &client, &terminals[..256].iter().map(String::as_str).collect::<Vec<_>>());
    // 256 is within the cap, and the frontend is asked about those terminals.
    let answers = ask(&mux, 1, 7, &terminals[0]);
    read_event(&client.outbound);
    assert!(answers.try_recv().is_err());
}
