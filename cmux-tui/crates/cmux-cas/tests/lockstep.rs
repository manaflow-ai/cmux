//! Lockstep: a `cas/1` version 1 peer against a newer one, both ways, over a byte stream.
//!
//! Leo, 2026-11-24 12:31Z: "of course acpmux/cmux protocols need to be able to work in lockstep
//! with these and improve ever further". The newer peer here is a simulated version 2 encoder:
//! it adds fields version 1 has no tag for (a Bao outboard on `DATA`, a bloom on `HAVE`, a
//! deadline on `WANT`) and a message kind version 1 does not know (`PATCH?`).

use cmux_cas::peer::{accept, respond};
use cmux_cas::wire::{Frame, KIND_DATA, KIND_HAVE, KIND_NOPE, KIND_WANT, tag};
use cmux_cas::wire::{Message, VERSION};
use cmux_cas::{Id, Store};

const V2: u16 = 2;
/// Tags version 1 does not know.
const TAG_OUTBOARD: u8 = 40;
const TAG_BLOOM: u8 = 41;
const TAG_DEADLINE: u8 = 42;
/// A kind version 1 does not know.
const KIND_PATCH: u8 = 5;

/// Frames on a byte stream, each one written and read back the way a link would.
fn over_the_wire(frames: &[Frame]) -> Vec<Frame> {
    let mut stream = Vec::new();
    for f in frames {
        f.write_to(&mut stream).unwrap();
    }
    let mut input = stream.as_slice();
    let mut out = Vec::new();
    while let Some(f) = Frame::read_from(&mut input).unwrap() {
        out.push(f);
    }
    out
}

/// A version 2 peer: answers what it knows; reads a version 1 `NOPE` of a kind as "fall back".
struct V2Peer {
    store: Store,
}

impl V2Peer {
    fn want(&self, ids: &[Id]) -> Frame {
        Frame {
            version: V2,
            kind: KIND_WANT,
            fields: vec![
                (TAG_DEADLINE, 250u32.to_le_bytes().to_vec()),
                (tag::IDS, ids.iter().flat_map(|id| id.0).collect()),
                (tag::PRIORITY, vec![1]),
            ],
        }
    }

    fn have(&self, root: Id) -> Frame {
        Frame {
            version: V2,
            kind: KIND_HAVE,
            fields: vec![(tag::ROOT, root.0.to_vec()), (TAG_BLOOM, vec![0xff; 64])],
        }
    }

    fn patch(&self, base: Id, target: Id) -> Frame {
        Frame {
            version: V2,
            kind: KIND_PATCH,
            fields: vec![(tag::IDS, [base.0, target.0].concat())],
        }
    }

    /// The v2 answer to a WANT: v1's DATA fields plus an outboard v1 never heard of.
    fn answer_want(&self, frame: &Frame) -> Vec<Frame> {
        let ids = frame.field(tag::IDS).unwrap();
        ids.chunks(32)
            .map(|id| {
                let id = Id(id.try_into().unwrap());
                let bytes = self.store.get(&id).unwrap();
                Frame {
                    version: V2,
                    kind: KIND_DATA,
                    fields: vec![
                        (TAG_OUTBOARD, vec![0xab; 128]),
                        (tag::ID, id.0.to_vec()),
                        (tag::BYTES, bytes),
                    ],
                }
            })
            .collect()
    }
}

#[test]
fn lockstep_v1_and_v2_peers_interoperate_both_ways() {
    let dirs: Vec<_> = (0..4).map(|_| tempfile::tempdir().unwrap()).collect();
    let chunk_a = b"chunk a: a v2 peer serves this to a v1 peer".to_vec();
    let chunk_b = b"chunk b: a v1 peer serves this to a v2 peer".to_vec();

    // --- Direction 1: a v1 client asks a v2 server. ---
    let v2 = V2Peer { store: Store::new(dirs[0].path()) };
    let id_a = Id::of(&chunk_a);
    v2.store.put(&id_a, &chunk_a).unwrap();
    let v1_client = Store::new(dirs[1].path());
    let ask = Message::Want { version: VERSION, ids: vec![id_a], priority: 0 };
    let [ask] = over_the_wire(&[ask.to_frame()]).try_into().unwrap();
    assert_eq!(ask.version, VERSION);
    let replies = over_the_wire(&v2.answer_want(&ask));
    for reply in &replies {
        assert_eq!(reply.version, V2);
        // v1 skips the outboard tag it does not know and reads the chunk.
        let message = Message::from_frame(reply).unwrap();
        assert_eq!(message.version(), V2);
        assert_eq!(accept(&v1_client, &message).unwrap(), Some(id_a));
    }
    assert_eq!(v1_client.get(&id_a).unwrap(), chunk_a);

    // A v2 HAVE with a bloom v1 cannot read still gives v1 the root.
    let [have] = over_the_wire(&[v2.have(Id([9; 32]))]).try_into().unwrap();
    assert!(matches!(
        Message::from_frame(&have).unwrap(),
        Message::Have { version: V2, root: Some(r), ids } if r == Id([9; 32]) && ids.is_empty()
    ));

    // --- Direction 2: a v2 client asks a v1 server. ---
    let v1_server = Store::new(dirs[2].path());
    let id_b = Id::of(&chunk_b);
    v1_server.put(&id_b, &chunk_b).unwrap();
    let v2_client = Store::new(dirs[3].path());
    let [want] = over_the_wire(&[v2.want(&[id_b])]).try_into().unwrap();
    // v1 reads the v2 WANT, ignoring the deadline, and answers in v1.
    let asked = Message::from_frame(&want).unwrap();
    assert!(
        matches!(&asked, Message::Want { version: V2, ids, priority: 1 } if *ids == vec![id_b])
    );
    let answers: Vec<Frame> =
        respond(&v1_server, &asked).unwrap().iter().map(Message::to_frame).collect();
    let answers = over_the_wire(&answers);
    assert_eq!(answers.len(), 1);
    // The v2 client reads the v1 DATA: the outboard field is absent, so it falls back to
    // checking the whole chunk against its id.
    assert_eq!(answers[0].version, VERSION);
    assert_eq!(answers[0].kind, KIND_DATA);
    assert!(answers[0].field(TAG_OUTBOARD).is_none());
    let data = Message::from_frame(&answers[0]).unwrap();
    assert_eq!(accept(&v2_client, &data).unwrap(), Some(id_b));
    assert_eq!(v2_client.get(&id_b).unwrap(), chunk_b);

    // A v2 message kind v1 does not know (PATCH?) is answered NOPE naming that kind and v1's
    // version, so the v2 peer falls back to plain WANTs.
    let [patch] = over_the_wire(&[v2.patch(id_a, id_b)]).try_into().unwrap();
    let unknown = Message::from_frame(&patch).unwrap();
    assert_eq!(unknown, Message::Unknown { version: V2, kind: KIND_PATCH });
    let nope = respond(&v1_server, &unknown).unwrap();
    let [nope] =
        over_the_wire(&nope.iter().map(Message::to_frame).collect::<Vec<_>>()).try_into().unwrap();
    assert_eq!((nope.version, nope.kind), (VERSION, KIND_NOPE));
    assert_eq!(nope.field(tag::KIND), Some(&[KIND_PATCH][..]));
    assert!(matches!(
        Message::from_frame(&nope).unwrap(),
        Message::Nope { version: 1, kind: Some(KIND_PATCH), ref ids, .. } if ids.is_empty()
    ));
}

#[test]
fn lockstep_v1_unknown_field_inside_a_known_message_is_ignored() {
    // Same version, one more field (a v1-plus build): every v1 message still reads.
    for m in [
        Message::Have { version: VERSION, root: Some(Id([1; 32])), ids: vec![Id([2; 32])] },
        Message::Want { version: VERSION, ids: vec![Id([3; 32])], priority: 4 },
        Message::Data { version: VERSION, id: Id([5; 32]), bytes: b"x".to_vec() },
        Message::Nope {
            version: VERSION,
            ids: vec![Id([6; 32])],
            kind: None,
            reason: "gone".into(),
        },
    ] {
        let mut frame = m.to_frame();
        frame.fields.insert(0, (200, b"from the future".to_vec()));
        frame.fields.push((201, Vec::new()));
        let [frame] = over_the_wire(&[frame]).try_into().unwrap();
        assert_eq!(Message::from_frame(&frame).unwrap(), m);
    }
}
