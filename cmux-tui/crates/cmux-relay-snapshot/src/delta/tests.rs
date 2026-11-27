use super::*;
use crate::seal;
use p256::SecretKey;
use p256::ecdsa::SigningKey;

fn identity() -> SigningKey {
    SigningKey::random(&mut rand_core::OsRng)
}

fn pk(key: &SigningKey) -> PublicKey {
    PublicKey::from(key.verifying_key())
}

const STREAM: &str = "chat:s1";

fn at(epoch: u64, seq: u64) -> Position {
    Position { epoch, seq }
}

struct Pair {
    source: SigningKey,
    viewer: SecretKey,
}

impl Pair {
    fn new() -> Self {
        Self { source: identity(), viewer: SecretKey::random(&mut rand_core::OsRng) }
    }

    fn delta(&self, position: Position, body: &[u8]) -> Vec<u8> {
        seal(&self.source, &self.viewer.public_key(), &delta_stream(STREAM), position, body)
            .unwrap()
    }

    fn apply(
        &self,
        floor: &mut Floor,
        envelopes: &[Vec<u8>],
    ) -> (Vec<Vec<u8>>, Option<ApplyError>) {
        let (opened, error) = apply(floor, &self.viewer, &pk(&self.source), STREAM, envelopes);
        (opened.into_iter().map(|o| o.plaintext).collect(), error)
    }
}

#[test]
fn a_resuming_viewer_gets_every_missed_delta_in_order() {
    let pair = Pair::new();
    let mut log = DeltaLog::new();
    for seq in 1..=5 {
        let body = format!("d{seq}");
        assert!(matches!(
            log.append(pair.delta(at(1, seq), body.as_bytes()), 0).unwrap(),
            Appended::Added { evicted: 0 }
        ));
    }
    let CatchUp::Deltas(deltas) = log.catch_up(at(1, 2), 1_000) else { panic!("gap") };
    assert_eq!(deltas.len(), 3);
    let mut floor = Floor::at(at(1, 2));
    let (opened, error) = pair.apply(&mut floor, &deltas);
    assert_eq!(error, None);
    assert_eq!(opened, vec![b"d3".to_vec(), b"d4".to_vec(), b"d5".to_vec()]);
    assert_eq!(floor.position(), Some(at(1, 5)));
}

#[test]
fn a_current_viewer_gets_nothing_and_a_far_behind_one_gets_a_gap() {
    let pair = Pair::new();
    let mut log = DeltaLog::new();
    assert_eq!(log.catch_up(at(1, 0), 0), CatchUp::Gap);
    for seq in 10..=12 {
        log.append(pair.delta(at(1, seq), b"x"), 0).unwrap();
    }
    assert_eq!(log.catch_up(at(1, 12), 0), CatchUp::Deltas(Vec::new()));
    assert_eq!(log.catch_up(at(1, 5), 0), CatchUp::Gap, "the log starts at 10: 6..9 are missing");
    assert_eq!(log.catch_up(at(0, 99), 0), CatchUp::Gap, "another epoch");
    assert_eq!(log.catch_up(at(1, 13), 0), CatchUp::Gap, "ahead of the log");
    assert!(matches!(log.catch_up(at(1, 9), 0), CatchUp::Deltas(d) if d.len() == 3));
}

#[test]
fn a_hole_or_new_epoch_restarts_the_log_and_retries_are_ignored() {
    let pair = Pair::new();
    let mut log = DeltaLog::new();
    log.append(pair.delta(at(1, 1), b"a"), 0).unwrap();
    log.append(pair.delta(at(1, 2), b"b"), 0).unwrap();
    assert_eq!(log.append(pair.delta(at(1, 2), b"b"), 0).unwrap(), Appended::Duplicate);
    assert_eq!(log.append(pair.delta(at(1, 1), b"a"), 0).unwrap(), Appended::Duplicate);
    assert_eq!(
        log.append(pair.delta(at(1, 4), b"d"), 0).unwrap(),
        Appended::Restarted { dropped: 2 }
    );
    assert_eq!(log.catch_up(at(1, 2), 0), CatchUp::Gap, "3 never arrived");
    assert_eq!(
        log.append(pair.delta(at(2, 0), b"e"), 0).unwrap(),
        Appended::Restarted { dropped: 1 }
    );
    assert_eq!(log.len(), 1);
}

#[test]
fn deltas_expire_with_the_mailbox_and_drain_on_delivery() {
    let pair = Pair::new();
    let mut log = DeltaLog::new();
    log.append(pair.delta(at(1, 1), b"a"), 0).unwrap();
    log.append(pair.delta(at(1, 2), b"b"), TTL_MS / 2).unwrap();
    log.append(pair.delta(at(1, 3), b"c"), TTL_MS / 2).unwrap();
    assert_eq!(log.catch_up(at(1, 0), TTL_MS), CatchUp::Gap, "1 expired");
    assert!(matches!(log.catch_up(at(1, 1), TTL_MS), CatchUp::Deltas(d) if d.len() == 2));
    log.drain_through(at(1, 2));
    assert_eq!(log.len(), 1);
    log.drain_through(at(1, 3));
    assert!(log.is_empty());
    assert_eq!(log.bytes(), 0);
    assert_eq!(
        log.catch_up(at(1, 3), TTL_MS),
        CatchUp::Deltas(Vec::new()),
        "drained, still current"
    );
    log.expire(TTL_MS * 3);
    assert_eq!(log.head(), Some(at(1, 3)));
}

#[test]
fn the_log_stays_within_its_count_and_byte_bounds() {
    let pair = Pair::new();
    let mut log = DeltaLog::new();
    for seq in 1..=(MAX_ENTRIES as u64 + 10) {
        log.append(pair.delta(at(1, seq), b"x"), 0).unwrap();
    }
    assert_eq!(log.len(), MAX_ENTRIES);
    assert_eq!(log.catch_up(at(1, 5), 0), CatchUp::Gap);
    let big = vec![7u8; 200 * 1024];
    let mut log = DeltaLog::new();
    for seq in 1..=10 {
        log.append(pair.delta(at(1, seq), &big), 0).unwrap();
    }
    assert!(log.bytes() <= MAX_LOG_BYTES);
    assert!(log.len() < 10);
}

#[test]
fn another_source_key_is_refused() {
    let (pair, other) = (Pair::new(), Pair::new());
    let mut log = DeltaLog::new();
    log.append(pair.delta(at(1, 1), b"a"), 0).unwrap();
    assert_eq!(log.append(other.delta(at(1, 2), b"b"), 0), Err(Error::WrongSource));
    assert_eq!(log.append(vec![1, 2, 3], 0), Err(Error::Malformed));
}

#[test]
fn the_viewer_refuses_holes_reorders_replays_and_snapshots_served_as_deltas() {
    let pair = Pair::new();
    let d = |seq| pair.delta(at(1, seq), format!("d{seq}").as_bytes());
    // A hole: 3 after 1.
    let mut floor = Floor::at(at(1, 1));
    let (opened, error) = pair.apply(&mut floor, &[d(2), d(4)]);
    assert_eq!(opened, vec![b"d2".to_vec()]);
    assert_eq!(error, Some(ApplyError::NotNext { want: Some(at(1, 3)), got: at(1, 4) }));
    assert_eq!(floor.position(), Some(at(1, 2)));
    // A replay of what the viewer already has.
    let (opened, error) = pair.apply(&mut floor, &[d(2)]);
    assert!(opened.is_empty());
    assert_eq!(error, Some(ApplyError::NotNext { want: Some(at(1, 3)), got: at(1, 2) }));
    // No base state: the viewer takes the snapshot first.
    let (_, error) = pair.apply(&mut Floor::default(), &[d(1)]);
    assert_eq!(error, Some(ApplyError::NotNext { want: None, got: at(1, 1) }));
    // A snapshot envelope (the snapshot stream) relabeled into a catch-up does not open as a delta.
    let snapshot = seal(&pair.source, &pair.viewer.public_key(), STREAM, at(1, 3), b"s").unwrap();
    let (_, error) = pair.apply(&mut floor, &[snapshot]);
    assert_eq!(error, Some(ApplyError::Seal(Error::BadSignature)));
}

#[test]
fn the_relay_holds_no_plaintext_and_cannot_relabel_a_position() {
    let pair = Pair::new();
    let needle = b"a distinctive delta the relay must not read";
    let mut envelope = pair.delta(at(1, 3), needle);
    assert!(!envelope.windows(needle.len()).any(|w| w == needle));
    // The relay rewrites seq 3 to seq 2 so it looks like the next delta.
    envelope[16] = 2;
    let mut floor = Floor::at(at(1, 1));
    let (_, error) = pair.apply(&mut floor, &[envelope]);
    assert_eq!(error, Some(ApplyError::Seal(Error::BadSignature)));
    assert_eq!(floor.position(), Some(at(1, 1)));
}

/// The catch-up path a resumed viewer runs: 200 missed deltas served and opened. Prints the time so the PR
/// can quote the relay-side and viewer-side cost (the network legs come from the conditions harness).
#[test]
fn catch_up_of_200_deltas_is_fast() {
    let pair = Pair::new();
    let mut log = DeltaLog::new();
    for seq in 1..=200 {
        log.append(pair.delta(at(1, seq), &[b'x'; 512]), 0).unwrap();
    }
    let started = std::time::Instant::now();
    let CatchUp::Deltas(deltas) = log.catch_up(at(1, 0), 1) else { panic!("gap") };
    let served = started.elapsed();
    let mut floor = Floor::at(at(1, 0));
    let (opened, error) = pair.apply(&mut floor, &deltas);
    let total = started.elapsed();
    assert_eq!(error, None);
    assert_eq!(opened.len(), 200);
    eprintln!("r9 catch-up: 200 deltas served in {served:?}, served and opened in {total:?}");
}
