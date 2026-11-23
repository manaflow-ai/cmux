use super::*;

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-screen-host-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    dir
}

#[test]
fn device_file_is_private_and_round_trips() {
    let dir = temp_dir("device");
    let device = Device::generate("desk").unwrap();
    device.save(&dir).unwrap();
    #[cfg(unix)]
    {
        let mode = fs::metadata(dir.join("device.json")).unwrap().mode() & 0o777;
        assert_eq!(mode, 0o600);
        assert_eq!(fs::metadata(&dir).unwrap().mode() & 0o777, 0o700);
    }
    let back = Device::load(&dir).unwrap().unwrap();
    assert_eq!(back.id, device.id);
    assert_eq!(back.id.len(), 36);
    assert_eq!(b64::decode(&back.signer().unwrap().public_key()).unwrap().len(), 65);
    assert_ne!(back.signer().unwrap().public_key(), back.agreement_key().unwrap());
    fs::remove_dir_all(&dir).unwrap();
}

/// An RNG for the test's sealing side, from ring's system randomness.
struct TestRng(SystemRandom);

impl hpke::rand_core::RngCore for TestRng {
    fn next_u32(&mut self) -> u32 {
        let mut b = [0; 4];
        self.fill_bytes(&mut b);
        u32::from_le_bytes(b)
    }
    fn next_u64(&mut self) -> u64 {
        let mut b = [0; 8];
        self.fill_bytes(&mut b);
        u64::from_le_bytes(b)
    }
    fn fill_bytes(&mut self, dest: &mut [u8]) {
        self.0.fill(dest).unwrap();
    }
}

impl hpke::rand_core::CryptoRng for TestRng {}

#[test]
fn relay_secrets_sealed_to_the_agreement_key_open() {
    use hpke::{Deserializable, Serializable};
    type Kem = hpke::kem::DhP256HkdfSha256;
    let device = Device::generate("desk").unwrap();
    // What a viewer does with the registered agreement key (base64 X9.63, 65 bytes).
    let public = b64::decode(&device.agreement_key().unwrap()).unwrap();
    let public = <Kem as hpke::Kem>::PublicKey::from_bytes(&public).unwrap();
    let info = b"cmux-device-hub relay v1 relay-1";
    let secret = br#"{"username":"u","credential":"c"}"#;
    let (encapsulated, ciphertext) =
        hpke::single_shot_seal::<hpke::aead::AesGcm256, hpke::kdf::HkdfSha256, Kem, _>(
            &hpke::OpModeS::Base,
            &public,
            info,
            secret,
            &[],
            &mut TestRng(SystemRandom::new()),
        )
        .unwrap();
    let encapsulated = encapsulated.to_bytes();
    assert_eq!(encapsulated.len(), 65);
    let opened = device.open_sealed(&ciphertext, &encapsulated, info).unwrap();
    assert_eq!(opened, secret);
    // Another relay's info, another device, or a changed byte opens nothing.
    assert!(device
        .open_sealed(&ciphertext, &encapsulated, b"cmux-device-hub relay v1 relay-2")
        .is_err());
    let other = Device::generate("other").unwrap();
    assert!(other.open_sealed(&ciphertext, &encapsulated, info).is_err());
    let mut tampered = ciphertext.clone();
    tampered[0] ^= 1;
    assert!(device.open_sealed(&tampered, &encapsulated, info).is_err());
    assert!(device.open_sealed(&ciphertext, &encapsulated[1..], info).is_err());
}

#[test]
#[cfg(unix)]
fn readable_or_symlinked_files_are_refused() {
    let dir = temp_dir("perms");
    Account { hub: "https://hub".into(), user_id: "p:u".into(), anchored_until: 0 }
        .save(&dir)
        .unwrap();
    let path = dir.join("account.json");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(Account::load(&dir).is_err());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    assert!(Account::load(&dir).unwrap().is_some());
    let link = dir.join("device.json");
    std::os::unix::fs::symlink(&path, &link).unwrap();
    assert!(Device::load(&dir).is_err());
    fs::remove_dir_all(&dir).unwrap();
}

#[test]
#[cfg(windows)]
fn windows_files_round_trip_and_a_directory_in_their_place_is_refused() {
    let dir = temp_dir("win");
    let account = Account { hub: "https://hub".into(), user_id: "p:u".into(), anchored_until: 1 };
    account.save(&dir).unwrap();
    // A second save replaces the first (rename over an existing file).
    let later = Account { anchored_until: 2, ..account };
    later.save(&dir).unwrap();
    assert_eq!(Account::load(&dir).unwrap(), Some(later));
    fs::create_dir(dir.join("device.json")).unwrap();
    assert!(Device::load(&dir).is_err());
    assert!(config_dir().unwrap().ends_with("cmux\\screen-host"));
    assert!(runtime_dir().unwrap().ends_with("screen-host\\run"));
    assert!(!host_name().is_empty());
    fs::remove_dir_all(&dir).unwrap();
}
