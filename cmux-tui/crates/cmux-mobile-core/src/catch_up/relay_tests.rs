use super::*;
use cmux_relay_snapshot::delta::{CatchUp, DeltaLog};
use p256::SecretKey;
use p256::ecdsa::SigningKey;

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

fn reply(entries: &[(&str, Vec<Vec<u8>>, u64)], cut: &[&str]) -> Vec<u8> {
    let surfaces: Vec<Value> = entries
        .iter()
        .map(|(surface, sealed, head)| {
            let sealed: Vec<String> = sealed.iter().map(|e| URL_SAFE_NO_PAD.encode(e)).collect();
            json!({
                "surface": delta::delta_stream(surface),
                "sealed": sealed,
                "head": { "epoch": 7, "seq": head },
            })
        })
        .collect();
    let cut: Vec<String> = cut.iter().map(|s| delta::delta_stream(s)).collect();
    json!({ "fromRelay": true, "surfaces": surfaces, "cut": cut }).to_string().into_bytes()
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
    let CatchUp::Deltas(sealed) = log.catch_up(Position { epoch: 7, seq: 3 }, 0) else {
        panic!("gap")
    };
    let mut floors = floors_at(&[&surface], 3);
    let body = request(&floors, std::slice::from_ref(&surface), 0).unwrap();
    assert_eq!(body["surfaces"][0]["surface"], "chat/s1/delta");
    assert_eq!(body["surfaces"][0]["after"], json!({ "epoch": 7, "seq": 3 }));
    assert_eq!(body["budgetBytes"], super::super::WAKE_BUDGET_BYTES);

    let got = read(&mut floors, &pair.phone, &pair.source(), &reply(&[(&surface, sealed, 6)], &[]))
        .unwrap();
    let through: Vec<_> = got.answers.iter().map(|a| a.chats[0].through_seq).collect();
    assert_eq!(through, [Some(40), Some(50), Some(60)]);
    assert!(got.cut.is_empty(), "{:?}", got.cut);
    assert_eq!(got.acks, [("chat/s1/delta".to_string(), Position { epoch: 7, seq: 6 })]);
    assert_eq!(floors.get(&surface), Some(Position { epoch: 7, seq: 6 }));
}

#[test]
fn every_surface_maps_to_its_mac_answer_field() {
    let pair = Pair::new();
    let mut floors = floors_at(&["workspaces", "chat-list"], 0);
    let body = reply(
        &[
            ("workspaces", vec![pair.seal("workspaces", 1, &json!({ "tree_revision": "r2" }))], 1),
            (
                "chat-list",
                vec![pair.seal("chat-list", 1, &json!({ "follow": true, "gone": [] }))],
                1,
            ),
        ],
        &[],
    );
    let got = read(&mut floors, &pair.phone, &pair.source(), &body).unwrap();
    assert_eq!(got.answers.len(), 2);
    assert!(got.answers[0].workspaces.is_some());
    assert_eq!(got.answers[1].chat_list, Some(json!({ "follow": true, "gone": [] })));
}

#[test]
fn a_hole_keeps_what_applied_and_cuts_the_surface() {
    let pair = Pair::new();
    let surface = chat_surface("s1");
    let mut floors = floors_at(&[&surface], 0);
    let sealed =
        vec![pair.seal(&surface, 1, &chat("s1", 1)), pair.seal(&surface, 3, &chat("s1", 3))];
    let got = read(&mut floors, &pair.phone, &pair.source(), &reply(&[(&surface, sealed, 3)], &[]))
        .unwrap();
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
    let sealed = vec![pair.seal(&surface, 1, &chat("s1", 1))];
    let got = read(&mut floors, &pair.phone, &pair.source(), &reply(&[(&surface, sealed, 5)], &[]))
        .unwrap();
    assert_eq!(got.answers.len(), 1);
    assert_eq!(got.cut_why["chats:s1"], "short");
}

#[test]
fn another_keys_seal_or_another_chats_page_is_refused() {
    let pair = Pair::new();
    let stranger = Pair::new();
    let surface = chat_surface("s1");
    let mut floors = floors_at(&[&surface, "chat/s2"], 0);
    let body = reply(
        &[
            (&surface, vec![stranger.seal(&surface, 1, &chat("s1", 1))], 1),
            // Sealed for s2's stream but naming s1: refused as not s2's page.
            ("chat/s2", vec![pair.seal("chat/s2", 1, &chat("s1", 1))], 1),
        ],
        &[],
    );
    let got = read(&mut floors, &pair.phone, &pair.source(), &body).unwrap();
    assert!(got.answers.is_empty());
    assert_eq!(got.cut_why["chats:s1"], "seal");
    assert_eq!(got.cut_why["chats:s2"], "plaintext");
    assert!(got.acks.is_empty());
    assert_eq!(floors.get(&surface), Some(Position { epoch: 7, seq: 0 }));
}

#[test]
fn the_relays_cut_and_unasked_surfaces() {
    let pair = Pair::new();
    let mut floors = floors_at(&["workspaces"], 0);
    // Only surfaces with a floor are asked; none at all asks nothing.
    assert!(request(&Floors::default(), &["workspaces".into()], 0).is_none());
    let body =
        request(&floors, &["chat/x".into(), "workspaces".into(), "workspaces".into()], 1 << 30)
            .unwrap();
    assert_eq!(body["surfaces"].as_array().unwrap().len(), 1);
    assert_eq!(body["budgetBytes"], MAX_BUDGET_BYTES);
    let got =
        read(&mut floors, &pair.phone, &pair.source(), &reply(&[], &["workspaces", "chat/x"]))
            .unwrap();
    assert_eq!(got.cut, ["workspaces", "chats:x"]);
    assert_eq!(read(&mut floors, &pair.phone, &pair.source(), b"{}"), Err(ReadError::NotRelay));
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
    let big = (1u64 << 53) + 1;
    assert_eq!(ack(Position { epoch: big, seq: 1 })["through"]["epoch"], big.to_string());
}

#[test]
fn a_mac_reply_names_its_relay_heads() {
    let answer =
        service::read(br#"{"v":1,"relay":{"chat/a":{"epoch":3,"seq":"9"},"bad":{"epoch":1}}}"#)
            .unwrap();
    assert_eq!(answer.relay_heads, [("chat/a".to_string(), (3, 9))].into());
}
