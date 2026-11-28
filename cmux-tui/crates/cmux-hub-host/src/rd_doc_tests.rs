use super::*;
use crate::identity::Device;

const KEY: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

#[test]
fn fp_sig_verifies_only_for_the_peer_role_and_key() {
    let viewer = Device::generate("viewer").unwrap().signer().unwrap();
    let other = Device::generate("other").unwrap().signer().unwrap();
    let sdp = RdDocument { key: KEY.into(), ..RdDocument::default() }.text();
    let fp = fingerprint_of(&sdp).unwrap();
    let sig = b64::encode(&viewer.sign(&fingerprint_message("sid", "viewer", &fp)).unwrap());
    assert!(verify_fp_sig(&sdp, &sig, "sid", "viewer", &viewer.public_key()));
    assert!(!verify_fp_sig(&sdp, &sig, "sid", "host", &viewer.public_key()));
    assert!(!verify_fp_sig(&sdp, &sig, "other-sid", "viewer", &viewer.public_key()));
    assert!(!verify_fp_sig(&sdp, &sig, "sid", "viewer", &other.public_key()));
    let tampered = RdDocument { key: KEY.replace("00", "ff"), ..RdDocument::default() }.text();
    assert!(!verify_fp_sig(&tampered, &sig, "sid", "viewer", &viewer.public_key()));
}
