//! The install key (ECDSA P-256, SHA-256) and the signed mesh message
//! (cx-0op.4). The golden signatures were computed by an independent pure
//! Python P-256 + RFC 6979 signer that reproduces the RFC 6979 A.2.5 vector,
//! and they are checked again here with the p256 verifier.

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use cmux_mesh_agent::install::{self, InstallKey, Purpose};
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};

/// RFC 6979 A.2.5: the P-256 private key and its public point.
const RFC_X: &str = "c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721";
const RFC_UX: &str = "60fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6";
const RFC_UY: &str = "7903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299";
/// RFC 6979 A.2.5, SHA-256, message "sample": r || s.
const RFC_SAMPLE_SIG: &str = "efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716\
                              f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8";
/// The P-256 base point G: the public key of the scalar 1.
const G_X: &str = "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296";
const G_Y: &str = "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5";

const WG_KEY: &str = "HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=";
const RFC_INSTALL_PUBLIC: &str =
    "BGD+1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p+2eQP+EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk=";
const NONCE: &str = "AAECAwQFBgcICQoLDA0ODw";
const SIGNED_AT: u64 = 1_791_331_200_000;

const GOLDEN_ENROLL: &str = "cmux-mesh-v1\nenroll\nmesh_abc\n\
    HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=\n\
    BGD+1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p+2eQP+EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk=\n\
    laptop\n1791331200000\nAAECAwQFBgcICQoLDA0ODw";
const GOLDEN_ENROLL_SIG: &str =
    "i8TqKGzQLbUWcDdlnMbuVFJEqnlpbxgixFOerp5WpH2vrkDiUl5c0/PVTwwll1iXLfbtnmhc6klXWY7rn5oF8w==";
const GOLDEN_ROTATE: &str = "cmux-mesh-v1\nrotate-key\ndev_1\n\
    HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=\n\
    BGD+1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p+2eQP+EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk=\n\
    \n1791331200000\nAAECAwQFBgcICQoLDA0ODw";
const GOLDEN_ROTATE_SIG: &str =
    "dsakA1uAobgxdRgVmU2Ysxuf2G3BLf66SS+VWllSzdMlQ2BdhUDfK1GZqtcPsEaT5shkpIUpikxBEpCuMBvIHA==";

fn hex(text: &str) -> Vec<u8> {
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap()).collect()
}

fn scalar(text: &str) -> [u8; 32] {
    hex(text).try_into().unwrap()
}

fn rfc_key() -> InstallKey {
    InstallKey::from_scalar(&scalar(RFC_X)).unwrap()
}

/// Verify with p256 directly, from the wire encodings only.
fn p256_verifies(public_b64: &str, message: &[u8], signature_b64: &str) -> bool {
    let public = STANDARD.decode(public_b64).unwrap();
    let Ok(key) = VerifyingKey::from_sec1_bytes(&public) else { return false };
    let Ok(signature) = Signature::from_slice(&STANDARD.decode(signature_b64).unwrap()) else {
        return false;
    };
    key.verify(message, &signature).is_ok()
}

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        static COUNT: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "cmux-mesh-install-test-{}-{}",
            std::process::id(),
            COUNT.fetch_add(1, Ordering::SeqCst)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn enroll_message_bytes_are_golden() {
    let message = install::message(
        Purpose::Enroll,
        "mesh_abc",
        WG_KEY,
        RFC_INSTALL_PUBLIC,
        "laptop",
        SIGNED_AT,
        NONCE,
    );
    assert_eq!(message, GOLDEN_ENROLL);
    assert_eq!(message.split('\n').count(), 8);
    assert!(!message.ends_with('\n'));
}

#[test]
fn rotate_message_has_an_empty_name_line() {
    let message = install::message(
        Purpose::RotateKey,
        "dev_1",
        WG_KEY,
        RFC_INSTALL_PUBLIC,
        "",
        SIGNED_AT,
        NONCE,
    );
    assert_eq!(message, GOLDEN_ROTATE);
    assert_eq!(message.split('\n').nth(5), Some(""));
    assert_eq!(Purpose::Enroll.as_str(), "enroll");
    assert_eq!(Purpose::RotateKey.as_str(), "rotate-key");
}

/// M3 device-signed reads: purpose `peers` or `tunnel`, the device as target,
/// an empty WireGuard key line and an empty name line.
#[test]
fn device_read_messages_have_empty_key_and_name_lines() {
    assert_eq!(Purpose::Peers.as_str(), "peers");
    assert_eq!(Purpose::Tunnel.as_str(), "tunnel");
    let message =
        install::message(Purpose::Peers, "dev_1", "", RFC_INSTALL_PUBLIC, "", SIGNED_AT, NONCE);
    assert_eq!(
        message,
        format!("cmux-mesh-v1\npeers\ndev_1\n\n{RFC_INSTALL_PUBLIC}\n\n{SIGNED_AT}\n{NONCE}")
    );
    let key = rfc_key();
    let proof = install::prove_at(&key, Purpose::Tunnel, "dev_1", "", "", SIGNED_AT, NONCE.into());
    let signed =
        install::message(Purpose::Tunnel, "dev_1", "", RFC_INSTALL_PUBLIC, "", SIGNED_AT, NONCE);
    assert!(p256_verifies(RFC_INSTALL_PUBLIC, signed.as_bytes(), &proof.signature));
}

#[test]
fn signer_matches_rfc_6979_vector() {
    let key = rfc_key();
    assert_eq!(key.sign(b"sample").to_vec(), hex(RFC_SAMPLE_SIG));
    let mut point = vec![0x04];
    point.extend(hex(RFC_UX));
    point.extend(hex(RFC_UY));
    assert_eq!(key.public_key_bytes().to_vec(), point);
    assert_eq!(key.public_key_base64(), RFC_INSTALL_PUBLIC);
}

#[test]
fn scalar_one_has_the_base_point_as_public_key() {
    let mut one = [0u8; 32];
    one[31] = 1;
    let key = InstallKey::from_scalar(&one).unwrap();
    let mut point = vec![0x04];
    point.extend(hex(G_X));
    point.extend(hex(G_Y));
    assert_eq!(key.public_key_bytes().to_vec(), point);
}

#[test]
fn golden_signatures_match_the_independent_signer_and_verify() {
    let key = rfc_key();
    let enroll = install::prove_at(
        &key,
        Purpose::Enroll,
        "mesh_abc",
        WG_KEY,
        "laptop",
        SIGNED_AT,
        NONCE.to_string(),
    );
    assert_eq!(enroll.signed_at, SIGNED_AT);
    assert_eq!(enroll.nonce, NONCE);
    assert_eq!(enroll.signature, GOLDEN_ENROLL_SIG);
    assert!(p256_verifies(RFC_INSTALL_PUBLIC, GOLDEN_ENROLL.as_bytes(), GOLDEN_ENROLL_SIG));
    let rotate =
        install::prove_at(&key, Purpose::RotateKey, "dev_1", WG_KEY, "", SIGNED_AT, NONCE.into());
    assert_eq!(rotate.signature, GOLDEN_ROTATE_SIG);
    assert!(p256_verifies(RFC_INSTALL_PUBLIC, GOLDEN_ROTATE.as_bytes(), GOLDEN_ROTATE_SIG));
    // A signature does not carry over to the other purpose.
    assert!(!p256_verifies(RFC_INSTALL_PUBLIC, GOLDEN_ROTATE.as_bytes(), GOLDEN_ENROLL_SIG));
}

#[test]
fn signature_round_trip_and_tamper() {
    let key = InstallKey::generate().unwrap();
    let public = key.public_key_base64();
    let proof = install::prove(&key, Purpose::Enroll, "mesh_abc", WG_KEY, "laptop").unwrap();
    let message = install::message(
        Purpose::Enroll,
        "mesh_abc",
        WG_KEY,
        &public,
        "laptop",
        proof.signed_at,
        &proof.nonce,
    );
    assert!(p256_verifies(&public, message.as_bytes(), &proof.signature));
    let tampered = message.replace("laptop", "laptoq");
    assert!(!p256_verifies(&public, tampered.as_bytes(), &proof.signature));
    let other = InstallKey::generate().unwrap();
    assert!(!p256_verifies(&other.public_key_base64(), message.as_bytes(), &proof.signature));
}

#[test]
fn proof_uses_the_clock_and_a_fresh_nonce() {
    let key = InstallKey::generate().unwrap();
    let now =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
            as u64;
    let first = install::prove(&key, Purpose::RotateKey, "dev_1", WG_KEY, "").unwrap();
    let second = install::prove(&key, Purpose::RotateKey, "dev_1", WG_KEY, "").unwrap();
    assert!(first.signed_at >= now && first.signed_at < now + 5_000, "{}", first.signed_at);
    assert_ne!(first.nonce, second.nonce);
    for nonce in [&first.nonce, &second.nonce] {
        assert_eq!(nonce.len(), 22);
        assert_eq!(URL_SAFE_NO_PAD.decode(nonce).unwrap().len(), 16);
        assert!(nonce.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
    }
    assert_eq!(install::new_nonce().unwrap().len(), 22);
}

#[test]
fn wire_formats() {
    let key = InstallKey::generate().unwrap();
    let public = key.public_key_base64();
    assert_eq!(public.len(), 88);
    assert!(public.ends_with('=') && !public.ends_with("=="));
    let bytes = STANDARD.decode(&public).unwrap();
    assert_eq!(bytes.len(), 65);
    assert_eq!(bytes[0], 0x04);
    let signature = key.sign_base64(b"x");
    assert_eq!(signature.len(), 88);
    assert!(signature.ends_with("=="));
    assert_eq!(STANDARD.decode(&signature).unwrap().len(), 64);
    assert_eq!(key.sign(b"x").len(), 64);
}

#[test]
fn install_key_file_is_0600_base64_scalar_and_refuses_overwrite() {
    let dir = TempDir::new();
    let path = dir.path("install.key");
    let public = install::install_keygen(&path).unwrap();
    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.ends_with('\n') && text.matches('\n').count() == 1);
    let scalar = STANDARD.decode(text.trim_end()).unwrap();
    assert_eq!(scalar.len(), 32);
    let from_scalar = InstallKey::from_scalar(&scalar.try_into().unwrap()).unwrap();
    assert_eq!(from_scalar.public_key_base64(), public);
    assert_eq!(install::read_install_key_file(&path).unwrap().public_key_base64(), public);
    assert!(install::install_keygen(&path).is_err());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
}

#[test]
fn bad_install_key_files_are_rejected() {
    let dir = TempDir::new();
    let cases: [(&str, String); 4] = [
        ("zero", format!("{}\n", STANDARD.encode([0u8; 32]))),
        ("order", format!("{}\n", STANDARD.encode([0xffu8; 32]))),
        ("short", format!("{}\n", STANDARD.encode([1u8; 31]))),
        ("text", "not base64!\n".to_string()),
    ];
    for (name, contents) in cases {
        let path = dir.path(name);
        std::fs::write(&path, contents).unwrap();
        assert!(install::read_install_key_file(&path).is_err(), "{name} accepted");
    }
    assert!(InstallKey::from_scalar(&[0u8; 32]).is_err());
}

#[test]
fn install_key_debug_is_redacted() {
    let key = rfc_key();
    assert_eq!(format!("{key:?}"), "InstallKey(<redacted>)");
}
