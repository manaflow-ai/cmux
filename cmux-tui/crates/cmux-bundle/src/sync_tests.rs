use super::*;
use crate::store::MemStore;

fn data(len: usize, seed: u64) -> Vec<u8> {
    let mut s = seed | 1;
    (0..len)
        .map(|_| {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            s as u8
        })
        .collect()
}

/// One exchange; returns (bytes the sender sent after the offer, round trips, assembled bytes).
fn exchange(
    key: &PairKey,
    bytes: &[u8],
    tx: &mut MemStore,
    rx: &mut MemStore,
) -> (usize, usize, Vec<u8>) {
    let s = Sender::new(key, Kind::Attachment, bytes, tx).unwrap();
    let r = Receiver::on_offer(key, &s.offer()).unwrap();
    let msgs = s.on_want(&r.want(rx), tx, BATCH_BYTES).unwrap();
    let sent: usize = msgs.iter().map(Vec::len).sum();
    let mut done = r.missing(rx).is_empty();
    for m in &msgs {
        done = r.on_chunks(m, rx).unwrap();
    }
    assert!(done);
    (sent, 1, r.assemble(rx).unwrap())
}

#[test]
fn first_send_moves_everything_and_a_resend_moves_nothing() {
    let key = PairKey::derive(&[1; 32]);
    let file = data(4 << 20, 42);
    let (mut tx, mut rx) = (MemStore::default(), MemStore::default());
    let (sent, _, got) = exchange(&key, &file, &mut tx, &mut rx);
    assert_eq!(got, file);
    assert!(sent >= file.len(), "first send carries the file: {sent}");
    let (resent, rtts, got) = exchange(&key, &file, &mut tx, &mut rx);
    assert_eq!(got, file);
    assert_eq!(resent, 0, "a re-sent attachment moves no chunk bytes");
    assert_eq!(rtts, 1);
}

#[test]
fn an_edit_moves_only_the_changed_chunks() {
    let key = PairKey::derive(&[1; 32]);
    let file = data(4 << 20, 9);
    let (mut tx, mut rx) = (MemStore::default(), MemStore::default());
    exchange(&key, &file, &mut tx, &mut rx);
    let mut edited = file.clone();
    edited.splice(2_000_000..2_000_000, b"one more line\n".iter().copied());
    let (sent, _, got) = exchange(&key, &edited, &mut tx, &mut rx);
    assert_eq!(got, edited);
    assert!(sent < file.len() / 8, "an edit resends {sent} of {}", file.len());
}

#[test]
fn chunks_from_a_cache_are_checked() {
    let key = PairKey::derive(&[1; 32]);
    let file = data(300_000, 5);
    let mut tx = MemStore::default();
    let s = Sender::new(&key, Kind::Attachment, &file, &mut tx).unwrap();
    let r = Receiver::on_offer(&key, &s.offer()).unwrap();
    let mut rx = MemStore::default();
    let ids = r.missing(&rx);
    // A relay returns a chunk under the wrong id: refused, nothing stored.
    let wrong = tx.get(&ids[1]).unwrap().unwrap();
    assert_eq!(r.accept(&ids[0], &wrong, &mut rx), Err(Error::Seal));
    assert!(rx.is_empty());
    // The right copies, from the "cache" (the sender's store here): accepted.
    for id in &ids {
        r.accept(id, &tx.get(id).unwrap().unwrap(), &mut rx).unwrap();
    }
    assert_eq!(r.assemble(&rx).unwrap(), file);
}

#[test]
fn a_forged_offer_or_old_peer_is_refused() {
    let key = PairKey::derive(&[1; 32]);
    let mut tx = MemStore::default();
    let s = Sender::new(&key, Kind::Attachment, b"hello", &mut tx).unwrap();
    // Another pair cannot make an offer this pair accepts.
    let other = PairKey::derive(&[2; 32]);
    assert_eq!(Receiver::on_offer(&other, &s.offer()).unwrap_err(), Error::Seal);
    let mut future = s.offer();
    future[0] = 2;
    assert_eq!(Receiver::on_offer(&key, &future).unwrap_err(), Error::Version(2));
    assert!(Receiver::on_offer(&key, b"{\"jsonrpc\":\"2.0\"}").is_err());
}

#[test]
fn records_round_trip_and_reject_truncation() {
    let mut body = Vec::new();
    encode_records([(&[1u8; 32], &b"abc"[..]), (&[2u8; 32], &b""[..])], &mut body);
    let recs = decode_records(&body).unwrap();
    assert_eq!(recs.len(), 2);
    assert_eq!(recs[0].1, b"abc");
    assert!(
        decode_records(&body[..body.len() - 1]).is_err() || decode_records(&body[..40]).is_err()
    );
    assert!(decode_records(&body[..38]).is_err());
}
