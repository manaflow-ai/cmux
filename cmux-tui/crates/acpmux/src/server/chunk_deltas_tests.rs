//! `chunk_deltas.rs`: what a client that asked hears for each chunk, that the event it rebuilds
//! is the one it stands for, and that every other client hears the event as before, byte for byte.

use super::*;

const CHAT: &str = "019a6c1e-2b3f-7c41-9d5e-8f0a1b2c3d4e";
const AGENT: &str = "7f3e9a10-55b2-4c8d-a1e6-0b9c8d7e6f5a";
const TURN: &str = "019a6c1f-0000-7aaa-8bbb-cccccccccccc";

/// An `_acpmux/event`'s params for chunk `seq` of the reply `segment`, as `event_value` and the
/// hub's segment stamp make them.
fn chunk(seq: u64, at: u64, segment: u32, text: &str) -> Value {
    json!({
        "sessionId": CHAT,
        "seq": seq,
        "at": at,
        "dir": "in",
        "kind": "session/update",
        "msg": {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": AGENT,
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": text},
                },
                "_meta": {"acpmux": {"segment": format!("{TURN}.k3x9.{segment}")}},
            },
        },
    })
}

fn parts(m: &Message) -> (&str, &Value) {
    match m {
        Message::Notification { method, params: Some(params) } => (method, params),
        other => panic!("not a notification: {other:?}"),
    }
}

/// What a client does with the frames (`protocol/events.rs` `ChunkDelta`): each `_acpmux/event`
/// as it is, its `chunkRef`'s template kept; each `_acpmux/chunk` rebuilt from its template.
#[derive(Default)]
struct Client {
    templates: HashMap<u64, Value>,
}

impl Client {
    fn read(&mut self, m: &Message) -> Value {
        let (method, params) = parts(m);
        match method {
            method::MUX_EVENT => {
                let mut event = params.clone();
                if let Some(r) = event.as_object_mut().and_then(|o| o.remove("chunkRef")) {
                    self.templates.insert(r.as_u64().unwrap(), event.clone());
                }
                event
            }
            CHUNK => {
                let r = params["ref"].as_u64().unwrap();
                let t = self.templates.get_mut(&r).expect("a ref the client holds");
                t["seq"] = params["seq"].clone();
                t["at"] = json!(t["at"].as_u64().unwrap() + params["dt"].as_u64().unwrap());
                t["msg"]["params"]["update"]["content"]["text"] = params["text"].clone();
                t.clone()
            }
            other => panic!("unexpected {other}"),
        }
    }
}

fn on() -> ChunkDeltas {
    let d = ChunkDeltas::default();
    d.set_enabled(true);
    d
}

#[test]
fn a_client_that_did_not_ask_hears_each_event_byte_for_byte() {
    let d = ChunkDeltas::default();
    for seq in 1..=5 {
        let params = chunk(seq, 1_764_000_000_000 + seq * 50, 1, "tick ");
        let want = Message::notification(method::MUX_EVENT, params.clone()).to_line();
        assert_eq!(d.frame(CHAT, params).to_line(), want);
    }
}

#[test]
fn a_streamed_reply_goes_as_deltas_and_rebuilds_to_each_event() {
    let d = on();
    let mut client = Client::default();
    let mut methods = Vec::new();
    for seq in 10..20 {
        let params = chunk(seq, 1_764_000_000_000 + seq * 50, 1, &format!("tick{seq} "));
        let frame = d.frame(CHAT, params.clone());
        methods.push(parts(&frame).0.to_owned());
        assert_eq!(client.read(&frame), params, "chunk {seq} rebuilds to its event");
    }
    assert_eq!(methods[0], method::MUX_EVENT, "the first chunk goes whole");
    assert!(methods[1..].iter().all(|m| m == CHUNK), "{methods:?}");
}

/// The bound the bandwidth bench's streaming leg rests on: a chunk of a few bytes of text was
/// about 435 B as `_acpmux/event`; as a delta it is at most 100 (a 10,000-turn chat's seq).
#[test]
fn a_delta_frame_is_at_most_100_bytes_for_a_short_chunk() {
    let d = on();
    let full = d.frame(CHAT, chunk(40_000, 1_764_000_000_000, 1, "tick0 ")).to_line();
    let delta = d.frame(CHAT, chunk(40_001, 1_764_000_000_050, 1, "tick1 ")).to_line();
    assert!(full.len() > 300, "the whole event: {} B {full}", full.len());
    assert!(delta.len() <= 100, "the delta: {} B {delta}", delta.len());
}

#[test]
fn a_change_but_the_text_goes_whole_with_a_new_ref() {
    let d = on();
    let mut client = Client::default();
    let a = d.frame(CHAT, chunk(1, 100, 1, "a"));
    let b = d.frame(CHAT, chunk(2, 150, 2, "b"));
    let c = d.frame(CHAT, chunk(3, 200, 2, "c"));
    assert_eq!(parts(&a).0, method::MUX_EVENT);
    assert_eq!(parts(&b).0, method::MUX_EVENT, "a new reply segment goes whole");
    assert_ne!(parts(&a).1["chunkRef"], parts(&b).1["chunkRef"]);
    assert_eq!(parts(&c).0, CHUNK);
    assert_eq!(parts(&c).1["ref"], parts(&b).1["chunkRef"]);
    client.read(&a);
    client.read(&b);
    assert_eq!(client.read(&c), chunk(3, 200, 2, "c"));
}

#[test]
fn other_records_go_whole_without_a_ref() {
    let d = on();
    let mut thought = chunk(1, 100, 1, "x");
    thought["msg"]["params"]["update"]["sessionUpdate"] = json!("agent_thought_chunk");
    let mut image = chunk(2, 100, 1, "x");
    image["msg"]["params"]["update"]["content"] = json!({"type": "image", "data": "AA=="});
    for params in [thought, image, json!({"sessionId": CHAT, "seq": 3, "kind": "status"})] {
        let want = Message::notification(method::MUX_EVENT, params.clone()).to_line();
        assert_eq!(d.frame(CHAT, params).to_line(), want);
    }
}

#[test]
fn a_reattach_or_an_old_seq_goes_whole() {
    let d = on();
    assert_eq!(parts(&d.frame(CHAT, chunk(1, 100, 1, "a"))).0, method::MUX_EVENT);
    assert_eq!(parts(&d.frame(CHAT, chunk(2, 150, 1, "b"))).0, CHUNK);
    d.forget(CHAT);
    assert_eq!(parts(&d.frame(CHAT, chunk(3, 200, 1, "c"))).0, method::MUX_EVENT);
    assert_eq!(parts(&d.frame(CHAT, chunk(3, 200, 1, "c"))).0, method::MUX_EVENT, "no newer seq");
    assert_eq!(parts(&d.frame(CHAT, chunk(4, 100, 1, "d"))).0, method::MUX_EVENT, "earlier at");
}

#[test]
fn each_chat_keeps_its_own_template() {
    let d = on();
    let other = "019a6c1e-0000-7000-8000-000000000000";
    let mut o = chunk(1, 100, 1, "a");
    o["sessionId"] = json!(other);
    assert_eq!(parts(&d.frame(CHAT, chunk(1, 100, 1, "a"))).0, method::MUX_EVENT);
    assert_eq!(parts(&d.frame(other, o.clone())).0, method::MUX_EVENT);
    o["seq"] = json!(2);
    assert_eq!(parts(&d.frame(other, o)).0, CHUNK);
    assert_eq!(parts(&d.frame(CHAT, chunk(2, 150, 1, "b"))).0, CHUNK);
}

/// `same_shape` answers as building the shape and comparing did, for every way two events differ.
#[test]
fn the_in_place_shape_compare_answers_as_the_copy_did() {
    let base = chunk(1, 100, 1, "a");
    let mut variants = vec![base.clone(), chunk(9, 900, 1, "other text"), chunk(2, 100, 2, "a")];
    let edits: [fn(&mut Value); 12] = [
        |v| v["chunkRef"] = json!(7),
        |v| v["dir"] = json!("out"),
        |v| v["peer"] = json!("mac"),
        |v| _ = v.as_object_mut().unwrap().remove("kind"),
        |v| v["msg"]["params"]["update"]["messageId"] = json!("m1"),
        |v| v["msg"]["params"]["update"]["content"]["annotations"] = json!({}),
        |v| _ = v["msg"]["params"]["update"]["content"].as_object_mut().unwrap().remove("text"),
        |v| v["msg"]["params"]["update"]["content"] = json!("flat"),
        |v| v["msg"]["params"]["update"] = json!([1, 2]),
        |v| v["msg"]["params"] = json!(null),
        |v| v["msg"] = json!("raw"),
        |v| v["msg"]["params"]["sessionId"] = json!("another"),
    ];
    for edit in edits {
        let mut v = base.clone();
        edit(&mut v);
        variants.push(v);
    }
    variants.push(json!("not an object"));
    variants.push(json!({"seq": 1}));
    for a in &variants {
        let shape = shape_of(a);
        for b in &variants {
            assert_eq!(same_shape(&shape, b), shape == shape_of(b), "{a} vs {b}");
        }
    }
}

/// A frame of shared params is the frame of the same params owned, byte for byte.
#[test]
fn a_shared_frame_is_the_owned_frame() {
    let (owned, shared) = (on(), on());
    for (i, text) in ["a", "b", "c"].iter().enumerate() {
        let seq = i as u64 + 1;
        let mut p = chunk(seq, 100 * seq, if i == 2 { 2 } else { 1 }, text);
        assert_eq!(
            shared.frame_shared(CHAT, &p, 0).to_line(),
            owned.frame(CHAT, p.clone()).to_line(),
            "{p}"
        );
        p["kind"] = json!("status");
        assert_eq!(shared.frame_shared(CHAT, &p, 0).to_line(), owned.frame(CHAT, p).to_line());
    }
}

/// A connection's stream cursor (`prev`) given beside shared params frames as the same params
/// owned with `prev` set: whole, compact, and a new template alike.
#[test]
fn a_shared_frame_carries_its_prev() {
    let (owned, shared) = (on(), on());
    for (i, text) in ["a", "b", "c", "d"].iter().enumerate() {
        let seq = i as u64 + 1;
        let p = chunk(seq, 100 * seq, if i == 2 { 2 } else { 1 }, text);
        let mut with_prev = p.clone();
        with_prev["prev"] = json!(seq - 1);
        let want = owned.frame(CHAT, if seq > 1 { with_prev } else { p.clone() }).to_line();
        assert_eq!(shared.frame_shared(CHAT, &p, seq - 1).to_line(), want, "{p}");
        if seq > 1 {
            assert!(want.contains(&format!("\"prev\":{}", seq - 1)), "{want}");
        }
    }
}
