use super::*;

fn identity() -> SigningKey {
    SigningKey::random(&mut rand_core::OsRng)
}

fn viewer() -> SecretKey {
    SecretKey::random(&mut rand_core::OsRng)
}

fn pk(key: &SigningKey) -> PublicKey {
    PublicKey::from(key.verifying_key())
}

const P1: Position = Position { epoch: 1, seq: 5 };

#[test]
fn a_snapshot_round_trips_and_two_seals_differ() {
    let (source, viewer) = (identity(), viewer());
    let a = seal(&source, &viewer.public_key(), "chat:s1", P1, b"hello").unwrap();
    let b = seal(&source, &viewer.public_key(), "chat:s1", P1, b"hello").unwrap();
    assert_ne!(a, b);
    let opened = open(&viewer, &pk(&source), "chat:s1", None, &a).unwrap();
    assert_eq!(opened, Opened { position: P1, plaintext: b"hello".to_vec() });
    assert_eq!(peek(&a).unwrap(), Header { position: P1, source_key_id: key_id(&pk(&source)) });
}

#[test]
fn the_relay_sees_no_plaintext() {
    let (source, viewer) = (identity(), viewer());
    let needle = b"a distinctive chat tail that must not leak";
    let sealed = seal(&source, &viewer.public_key(), "chat:s1", P1, needle).unwrap();
    assert!(!sealed.windows(needle.len()).any(|w| w == needle));
}

#[test]
fn a_wrong_recipient_does_not_open() {
    let (source, viewer, other) = (identity(), viewer(), viewer());
    let sealed = seal(&source, &viewer.public_key(), "chat:s1", P1, b"x").unwrap();
    assert_eq!(open(&other, &pk(&source), "chat:s1", None, &sealed), Err(Error::BadSignature));
}

#[test]
fn another_stream_does_not_open() {
    let (source, viewer) = (identity(), viewer());
    let sealed = seal(&source, &viewer.public_key(), "chat:s1", P1, b"x").unwrap();
    // The stream is in the signed context: a relay swapping one stream's blob for another's is caught.
    assert!(open(&viewer, &pk(&source), "chat:s2", None, &sealed).is_err());
}

#[test]
fn any_flipped_byte_is_refused() {
    let (source, viewer) = (identity(), viewer());
    let sealed = seal(&source, &viewer.public_key(), "chat:s1", P1, b"some state").unwrap();
    for i in 0..sealed.len() {
        let mut bad = sealed.clone();
        bad[i] ^= 1;
        assert!(open(&viewer, &pk(&source), "chat:s1", None, &bad).is_err(), "byte {i}");
    }
    // A relabeled position (the header is signed and in the AAD) is refused, not just a body edit.
    let mut relabeled = sealed.clone();
    relabeled[16] = relabeled[16].wrapping_add(1);
    assert_eq!(open(&viewer, &pk(&source), "chat:s1", None, &relabeled), Err(Error::BadSignature));
    // A truncated or extended envelope is malformed.
    assert_eq!(
        open(&viewer, &pk(&source), "chat:s1", None, &sealed[..sealed.len() - 1]),
        Err(Error::Malformed)
    );
    let mut longer = sealed;
    longer.push(0);
    assert_eq!(open(&viewer, &pk(&source), "chat:s1", None, &longer), Err(Error::Malformed));
    assert_eq!(peek(b""), Err(Error::Malformed));
}

#[test]
fn a_signature_from_another_key_is_refused() {
    let (source, impostor, viewer) = (identity(), identity(), viewer());
    // An impostor (the relay with its own key, or a stolen viewer key) seals to the viewer as the source would.
    let forged = seal(&impostor, &viewer.public_key(), "chat:s1", P1, b"forged").unwrap();
    assert_eq!(open(&viewer, &pk(&source), "chat:s1", None, &forged), Err(Error::WrongSource));
    // Relabeling the key id to the source's does not help: the signature is by the impostor.
    let mut relabeled = forged;
    relabeled[17..49].copy_from_slice(&key_id(&pk(&source)));
    assert_eq!(open(&viewer, &pk(&source), "chat:s1", None, &relabeled), Err(Error::BadSignature));
}

#[test]
fn an_older_position_is_refused_and_a_newer_one_raises_the_floor() {
    let (source, viewer) = (identity(), viewer());
    let at = |epoch, seq| {
        seal(
            &source,
            &viewer.public_key(),
            "chat:s1",
            Position { epoch, seq },
            format!("{epoch}.{seq}").as_bytes(),
        )
        .unwrap()
    };
    let mut floor = Floor::default();
    assert_eq!(
        floor.open(&viewer, &pk(&source), "chat:s1", &at(2, 10)).unwrap().plaintext,
        b"2.10"
    );
    // Older seq in the same epoch, and a higher seq of an older epoch (a rolled-back source), are stale.
    for (epoch, seq) in [(2, 9), (1, 99)] {
        assert_eq!(
            floor.open(&viewer, &pk(&source), "chat:s1", &at(epoch, seq)),
            Err(Error::Stale {
                have: Position { epoch: 2, seq: 10 },
                got: Position { epoch, seq }
            })
        );
    }
    assert_eq!(floor.position(), Some(Position { epoch: 2, seq: 10 }));
    // The same position again is a harmless replay; a new epoch beats any seq of the old one.
    assert!(floor.open(&viewer, &pk(&source), "chat:s1", &at(2, 10)).is_ok());
    assert!(floor.open(&viewer, &pk(&source), "chat:s1", &at(3, 0)).is_ok());
    assert_eq!(floor.position(), Some(Position { epoch: 3, seq: 0 }));
    assert!(Position { epoch: 3, seq: 0 } > Position { epoch: 2, seq: u64::MAX });
}

#[test]
fn a_context_part_with_a_nul_is_refused() {
    let (source, viewer) = (identity(), viewer());
    assert_eq!(seal(&source, &viewer.public_key(), "a\0b", P1, b"x"), Err(Error::BadInput));
}

#[test]
fn an_oversize_snapshot_is_refused() {
    let (source, viewer) = (identity(), viewer());
    assert_eq!(
        seal(&source, &viewer.public_key(), "s", P1, &vec![0; MAX_PLAINTEXT + 1]),
        Err(Error::BadInput)
    );
    assert!(seal(&source, &viewer.public_key(), "s", P1, &vec![0; MAX_PLAINTEXT]).is_ok());
}

#[test]
fn the_wire_layout_is_pinned() {
    let source = SigningKey::from_slice(&[7u8; 32]).unwrap();
    let viewer = SecretKey::from_slice(&[9u8; 32]).unwrap();
    let ephemeral = SecretKey::from_slice(&[11u8; 32]).unwrap();
    let a =
        seal_with(&source, &viewer.public_key(), "s", P1, b"abc", &ephemeral, &[3u8; 12]).unwrap();
    let b =
        seal_with(&source, &viewer.public_key(), "s", P1, b"abc", &ephemeral, &[3u8; 12]).unwrap();
    assert_eq!(a, b);
    // version, epoch, seq, key id, point, nonce, length, ciphertext + tag, signature
    assert_eq!(a.len(), 1 + 8 + 8 + 32 + 65 + 12 + 4 + (3 + 16) + 64);
    assert_eq!(&a[..17], &[1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 5]);
    assert_eq!(&a[126..130], &19u32.to_be_bytes());
    assert_eq!(open(&viewer, &pk(&source), "s", None, &a).unwrap().plaintext, b"abc");
}
