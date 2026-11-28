//! Open tabs sealed with a profile key, the key wrapped to devices, a recovery key, and escrow only when switched on.

use cmux_browser_sync::envelope::{Envelope, OpenTab, OpenTabs};
use cmux_browser_sync::keys::{
    DeviceKey, EscrowPolicy, Keyring, ProfileKey, Recipient, RecoveryKey,
};

fn tabs(device: &str) -> OpenTabs {
    OpenTabs {
        device: device.into(),
        captured_at_ms: 1_700_000_000_000,
        tabs: vec![
            OpenTab {
                url: "https://example.com/a".into(),
                title: "A".into(),
                workspace: None,
                pinned: true,
            },
            OpenTab {
                url: "https://example.com/b".into(),
                title: "B".into(),
                workspace: Some("w1".into()),
                pinned: false,
            },
        ],
    }
}

#[test]
fn a_second_device_reads_tabs_sealed_on_the_first() {
    let mac = DeviceKey::generate("mac").unwrap();
    let phone = DeviceKey::generate("phone").unwrap();
    let recovery = RecoveryKey::generate().unwrap();
    let key = ProfileKey::generate().unwrap();
    let ring = Keyring::build(
        &key,
        "p1",
        1,
        &[("mac".into(), mac.public()), ("phone".into(), phone.public())],
        &recovery,
        &EscrowPolicy::None,
    )
    .unwrap();
    assert!(!ring.has_escrow());

    let sealed = tabs("mac").seal(&ring.open_for_device(&mac).unwrap(), "p1", 1).unwrap();
    let text = serde_json::to_string(&sealed).unwrap();
    assert!(!text.contains("example.com"), "no URL in the clear: {text}");

    let envelope: Envelope = serde_json::from_str(&text).unwrap();
    let read = OpenTabs::open(&envelope, &ring.open_for_device(&phone).unwrap()).unwrap();
    assert_eq!(read, tabs("mac"));
}

#[test]
fn recovery_key_opens_after_every_device_is_lost() {
    let mac = DeviceKey::generate("mac").unwrap();
    let recovery = RecoveryKey::generate().unwrap();
    let shown = recovery.display();
    assert_eq!(shown.len(), 64 + 7);
    let key = ProfileKey::generate().unwrap();
    let ring = Keyring::build(
        &key,
        "p1",
        1,
        &[("mac".into(), mac.public())],
        &recovery,
        &EscrowPolicy::None,
    )
    .unwrap();
    let sealed = tabs("mac").seal(&key, "p1", 1).unwrap();
    drop(mac);

    let typed = RecoveryKey::parse(&shown.to_uppercase().replace('-', " ")).unwrap();
    let opened = ring.open_with_recovery(&typed).unwrap();
    assert_eq!(OpenTabs::open(&sealed, &opened).unwrap(), tabs("mac"));

    let wrong = RecoveryKey::generate().unwrap();
    assert!(ring.open_with_recovery(&wrong).is_err());
}

#[test]
fn a_device_approves_a_new_one_and_removal_drops_its_wrap() {
    let mac = DeviceKey::generate("mac").unwrap();
    let laptop = DeviceKey::generate("laptop").unwrap();
    let key = ProfileKey::generate().unwrap();
    let mut ring = Keyring::build(
        &key,
        "p1",
        1,
        &[("mac".into(), mac.public())],
        &RecoveryKey::generate().unwrap(),
        &EscrowPolicy::None,
    )
    .unwrap();
    assert!(ring.open_for_device(&laptop).is_err());
    ring.approve_device(&mac, "laptop", &laptop.public()).unwrap();
    let sealed = tabs("mac").seal(&key, "p1", 1).unwrap();
    assert_eq!(
        OpenTabs::open(&sealed, &ring.open_for_device(&laptop).unwrap()).unwrap(),
        tabs("mac")
    );

    ring.remove_device("laptop");
    assert!(ring.open_for_device(&laptop).is_err());

    // A device key survives a restart through its secret bytes.
    let restored = DeviceKey::from_secret("mac", *mac.secret_bytes());
    assert!(ring.open_for_device(&restored).is_ok());
}

#[test]
fn escrow_wrap_exists_only_when_the_switch_is_on() {
    let escrow = DeviceKey::generate("escrow").unwrap();
    let key = ProfileKey::generate().unwrap();
    let recovery = RecoveryKey::generate().unwrap();
    let off = Keyring::build(&key, "p1", 1, &[], &recovery, &EscrowPolicy::None).unwrap();
    assert!(!off.has_escrow());
    assert_eq!(off.wraps.len(), 1);
    let on = Keyring::build(
        &key,
        "p1",
        1,
        &[],
        &recovery,
        &EscrowPolicy::Server { escrow_public: escrow.public() },
    )
    .unwrap();
    assert!(on.has_escrow());
    assert!(on.wraps.iter().any(|wrap| wrap.recipient == Recipient::Escrow));
}

#[test]
fn a_sealed_body_does_not_open_under_another_header_or_key() {
    let key = ProfileKey::generate().unwrap();
    let sealed = tabs("mac").seal(&key, "p1", 1).unwrap();

    let mut moved = sealed.clone();
    moved.profile = "p2".into();
    assert!(moved.open(&key).is_err(), "moved to another profile");

    let mut renamed = sealed.clone();
    renamed.record = "phone".into();
    assert!(renamed.open(&key).is_err(), "moved to another record");

    let mut bumped = sealed.clone();
    bumped.key_version = 2;
    assert!(bumped.open(&key).is_err(), "relabelled key version");

    assert!(sealed.open(&ProfileKey::generate().unwrap()).is_err(), "another key");

    let mut tampered = sealed;
    let mut bytes = tampered.ciphertext.into_bytes();
    bytes[3] = if bytes[3] == b'A' { b'B' } else { b'A' };
    tampered.ciphertext = String::from_utf8(bytes).unwrap();
    assert!(tampered.open(&key).is_err(), "changed ciphertext");
}

#[test]
fn a_wrap_for_one_profile_does_not_open_as_another() {
    let mac = DeviceKey::generate("mac").unwrap();
    let key = ProfileKey::generate().unwrap();
    let mut ring = Keyring::build(
        &key,
        "p1",
        1,
        &[("mac".into(), mac.public())],
        &RecoveryKey::generate().unwrap(),
        &EscrowPolicy::None,
    )
    .unwrap();
    ring.profile = "p2".into();
    for wrap in &mut ring.wraps {
        wrap.profile = "p2".into();
    }
    assert!(ring.open_for_device(&mac).is_err());
}
