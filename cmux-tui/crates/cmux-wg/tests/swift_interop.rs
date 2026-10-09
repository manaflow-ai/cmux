//! Interop with the Swift WireGuard engine of the iOS V2 carrier
//! (`Packages/Shared/CmuxLinkWG`, plans/cmux-next/ios-next/b3-webrtc-wg.md).
//!
//! The Swift test `HandshakeTests.goldenInitiation` builds a handshake
//! initiation from fixed keys, ephemeral, index and timestamp. boringtun
//! must accept those exact bytes and answer with a response: that checks
//! mac1, the encrypted static key and timestamp, and the whole Noise hash
//! chain of the Swift side.

use boringtun::noise::{Tunn, TunnResult};
use x25519_dalek::{PublicKey, StaticSecret};

/// Swift `WireGuardPrivateKey(rawRepresentation: 1...32)` (the device).
fn device_private() -> [u8; 32] {
    std::array::from_fn(|index| index as u8 + 1)
}

/// Swift `WireGuardPrivateKey(rawRepresentation: 33...64)` (the host).
fn host_private() -> [u8; 32] {
    std::array::from_fn(|index| index as u8 + 33)
}

const DEVICE_PUBLIC: &str = "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c";
const HOST_PUBLIC: &str = "5869aff450549732cbaaed5e5df9b30a6da31cb0e5742bad5ad4a1a768f1a67b";
const INITIATION: &str = "010000000102030464b101b1d0be5a8704bd078f9895001fc03e8e9f9522f188dd128d9846d48466158a0e4ca242d151ca97ab90159a98b67e616625e68b4065d357376b6598e644ad7d678c0295d22de4cb43d5135581ed36346bfa7cf42a122139f8939935ec574414e91f3b457e447709b4db79ef84cbbce8e408d4d15bac46c2b8fb00000000000000000000000000000000";

fn hex(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&text[index..index + 2], 16).expect("hex literal"))
        .collect()
}

#[test]
fn public_keys_match_cryptokit() {
    let device = PublicKey::from(&StaticSecret::from(device_private()));
    let host = PublicKey::from(&StaticSecret::from(host_private()));
    assert_eq!(device.as_bytes().to_vec(), hex(DEVICE_PUBLIC));
    assert_eq!(host.as_bytes().to_vec(), hex(HOST_PUBLIC));
}

#[test]
fn boringtun_answers_the_swift_initiation() {
    let device = PublicKey::from(&StaticSecret::from(device_private()));
    let mut host = Tunn::new(StaticSecret::from(host_private()), device, None, None, 7, None);
    let initiation = hex(INITIATION);
    assert_eq!(initiation.len(), 148);
    let mut buffer = [0u8; 256];
    match host.decapsulate(None, &initiation, &mut buffer) {
        TunnResult::WriteToNetwork(response) => {
            assert_eq!(response.len(), 92, "a handshake response");
            assert_eq!(response[0], 2);
            assert_eq!(&response[8..12], &[1, 2, 3, 4], "addressed to the Swift sender index");
        }
        other => panic!("boringtun refused the Swift initiation: {other:?}"),
    }
}

#[test]
fn boringtun_refuses_a_tampered_swift_initiation() {
    let device = PublicKey::from(&StaticSecret::from(device_private()));
    let mut host = Tunn::new(StaticSecret::from(host_private()), device, None, None, 7, None);
    let mut initiation = hex(INITIATION);
    initiation[60] ^= 1;
    let mut buffer = [0u8; 256];
    assert!(
        !matches!(host.decapsulate(None, &initiation, &mut buffer), TunnResult::WriteToNetwork(_)),
        "a flipped bit must not get a response"
    );
}
