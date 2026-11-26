use super::*;
use cmux_relay_snapshot::delta::{self, DeltaLog};
use p256::PublicKey;
use p256::SecretKey;
use p256::ecdsa::SigningKey;
use serde_json::{Value, json};

struct Pair {
    mac: SigningKey,
    phone: SecretKey,
}

impl Pair {
    fn new() -> Self {
        Self {
            mac: SigningKey::random(&mut rand_core::OsRng),
            phone: SecretKey::random(&mut rand_core::OsRng),
        }
    }

    fn source(&self) -> PublicKey {
        PublicKey::from(self.mac.verifying_key())
    }

    fn seal(&self, surface: &str, seq: u64, plaintext: &Value) -> Vec<u8> {
        cmux_relay_snapshot::seal(
            &self.mac,
            &self.phone.public_key(),
            &delta::delta_stream(surface),
            Position { epoch: 7, seq },
            plaintext.to_string().as_bytes(),
        )
        .unwrap()
    }
}

/// What the relay cache client does with one answered stream: `delta::apply` under its floor.
struct Applied {
    surface: String,
    applied: Vec<cmux_relay_snapshot::Opened>,
    stopped: Option<ApplyError>,
    head: Position,
}

fn apply(
    floors: &Floors,
    viewer: &Pair,
    source: &Pair,
    surface: &str,
    sealed: &[Vec<u8>],
    head: u64,
) -> Applied {
    let mut floor = Floor::at(floors.get(surface).unwrap());
    let (applied, stopped) =
        delta::apply(&mut floor, &viewer.phone, &source.source(), surface, sealed);
    Applied {
        surface: surface.to_string(),
        applied,
        stopped,
        head: Position { epoch: 7, seq: head },
    }
}

fn take_all(floors: &mut Floors, cut: &[&str], got: &[Applied]) -> RelayAnswer {
    let cut: Vec<String> = cut.iter().map(|s| s.to_string()).collect();
    let opened: Vec<Opened<'_>> = got
        .iter()
        .map(|a| Opened {
            surface: &a.surface,
            applied: &a.applied,
            stopped: a.stopped.as_ref(),
            head: a.head,
        })
        .collect();
    take(floors, &cut, &opened)
}

fn floors_at(surfaces: &[&str], seq: u64) -> Floors {
    let mut floors = Floors::default();
    let heads = surfaces.iter().map(|s| (s.to_string(), (7, seq))).collect();
    floors.set_from_mac(&heads);
    floors
}

fn chat(id: &str, through: u64) -> Value {
    json!({ "sessionId": id, "pageThrough": through, "messages": [{ "seq": through }] })
}

#[test]
fn deltas_from_the_relay_log_apply_in_order_as_mac_answers() {
    let pair = Pair::new();
    let surface = chat_surface("s1");
    let mut log = DeltaLog::new();
    for seq in 4..=6 {
        log.append(pair.seal(&surface, seq, &chat("s1", seq * 10)), 0).unwrap();
    }
    let delta::CatchUp::Deltas(sealed) = log.catch_up(Position { epoch: 7, seq: 3 }, 0) else {
        panic!("gap")
    };
    let mut floors = floors_at(&[&surface], 3);
    let asked = wanted(&floors, std::slice::from_ref(&surface));
    assert_eq!(asked.len(), 1);
    assert_eq!(asked[0].0, "chat/s1");
    assert_eq!(asked[0].1.position(), Some(Position { epoch: 7, seq: 3 }));

    let got = apply(&floors, &pair, &pair, &surface, &sealed, 6);
    let got = take_all(&mut floors, &[], &[got]);
    let through: Vec<_> = got.answers.iter().map(|a| a.chats[0].through_seq).collect();
    assert_eq!(through, [Some(40), Some(50), Some(60)]);
    assert!(got.cut.is_empty(), "{:?}", got.cut);
    assert_eq!(got.acks, [("chat/s1".to_string(), Position { epoch: 7, seq: 6 })]);
    assert_eq!(floors.get(&surface), Some(Position { epoch: 7, seq: 6 }));
}

#[test]
fn every_surface_maps_to_its_mac_answer_field() {
    let pair = Pair::new();
    let mut floors = floors_at(&["workspaces", "chat-list"], 0);
    let a = apply(
        &floors,
        &pair,
        &pair,
        "workspaces",
        &[pair.seal("workspaces", 1, &json!({ "tree_revision": "r2" }))],
        1,
    );
    let b = apply(
        &floors,
        &pair,
        &pair,
        "chat-list",
        &[pair.seal("chat-list", 1, &json!({ "follow": true, "gone": [] }))],
        1,
    );
    let got = take_all(&mut floors, &[], &[a, b]);
    assert_eq!(got.answers.len(), 2);
    assert!(got.answers[0].workspaces.is_some());
    assert_eq!(got.answers[1].chat_list, Some(json!({ "follow": true, "gone": [] })));
}

#[test]
fn a_hole_keeps_what_applied_and_cuts_the_surface() {
    let pair = Pair::new();
    let surface = chat_surface("s1");
    let mut floors = floors_at(&[&surface], 0);
    let sealed = [pair.seal(&surface, 1, &chat("s1", 1)), pair.seal(&surface, 3, &chat("s1", 3))];
    let got = apply(&floors, &pair, &pair, &surface, &sealed, 3);
    let got = take_all(&mut floors, &[], &[got]);
    assert_eq!(got.answers.len(), 1);
    assert_eq!(got.cut, ["chats:s1"]);
    assert_eq!(got.cut_why["chats:s1"], "hole");
    assert_eq!(floors.get(&surface), Some(Position { epoch: 7, seq: 1 }));
}

#[test]
fn a_relay_that_withholds_the_tail_is_cut_short() {
    let pair = Pair::new();
    let surface = chat_surface("s1");
    let mut floors = floors_at(&[&surface], 0);
    let got = apply(&floors, &pair, &pair, &surface, &[pair.seal(&surface, 1, &chat("s1", 1))], 5);
    let got = take_all(&mut floors, &[], &[got]);
    assert_eq!(got.answers.len(), 1);
    assert_eq!(got.cut_why["chats:s1"], "short");
}

#[test]
fn another_keys_seal_or_another_chats_page_is_refused() {
    let pair = Pair::new();
    let stranger = Pair::new();
    let surface = chat_surface("s1");
    let mut floors = floors_at(&[&surface, "chat/s2"], 0);
    let a =
        apply(&floors, &pair, &pair, &surface, &[stranger.seal(&surface, 1, &chat("s1", 1))], 1);
    // Sealed for s2's stream but naming s1: refused as not s2's page.
    let b = apply(&floors, &pair, &pair, "chat/s2", &[pair.seal("chat/s2", 1, &chat("s1", 1))], 1);
    let got = take_all(&mut floors, &[], &[a, b]);
    assert!(got.answers.is_empty());
    assert_eq!(got.cut_why["chats:s1"], "seal");
    assert_eq!(got.cut_why["chats:s2"], "plaintext");
    assert!(got.acks.is_empty());
    assert_eq!(floors.get(&surface), Some(Position { epoch: 7, seq: 0 }));
}

#[test]
fn the_relays_cut_and_unasked_surfaces() {
    let mut floors = floors_at(&["workspaces"], 0);
    // Only surfaces with a floor are asked, once each; none at all asks nothing.
    assert!(wanted(&Floors::default(), &["workspaces".into()]).is_empty());
    let asked = wanted(&floors, &["chat/x".into(), "workspaces".into(), "workspaces".into()]);
    assert_eq!(asked.len(), 1);
    assert_eq!(budget(0), super::super::WAKE_BUDGET_BYTES as usize);
    let got = take_all(&mut floors, &["workspaces", "chat/x"], &[]);
    assert_eq!(got.cut, ["workspaces", "chats:x"]);
}

#[test]
fn floors_round_trip_and_follow_the_mac() {
    let mut floors = floors_at(&["chat/a", "workspaces"], 5);
    assert_eq!(Floors::decode(&floors.encode()), floors);
    assert_eq!(Floors::decode(b"junk"), Floors::default());
    // Older in the same epoch: kept. Another epoch: replaced.
    floors.set_from_mac(&[("chat/a".to_string(), (7, 2))].into());
    assert_eq!(floors.get("chat/a"), Some(Position { epoch: 7, seq: 5 }));
    floors.set_from_mac(&[("chat/a".to_string(), (8, 1))].into());
    assert_eq!(floors.get("chat/a"), Some(Position { epoch: 8, seq: 1 }));
}

#[test]
fn a_mac_reply_names_its_relay_heads() {
    let answer =
        service::read(br#"{"v":1,"relay":{"chat/a":{"epoch":3,"seq":"9"},"bad":{"epoch":1}}}"#)
            .unwrap();
    assert_eq!(answer.relay_heads, [("chat/a".to_string(), (3, 9))].into());
}
