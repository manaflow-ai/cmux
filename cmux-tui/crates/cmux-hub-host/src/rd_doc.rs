//! The cmux.rd/1 offer and answer documents a hub session's signaling carries and the session's
//! ICE servers (cmux-rd-proto's `rd_doc`, shared with the Mac app), and the fingerprint signature
//! both sides put on them (`fpSig`, PROTOCOL.md Session flow 5).

use crate::b64;
pub use cmux_rd_proto::rd_doc::{
    fingerprint_message, fingerprint_of, is_relayed, servers, RdDocument, Turn, HEADER, KEY_PREFIX,
};

/// Whether `fp_sig` (base64 raw r||s) is `peer_key`'s signature of `role`'s fingerprint in `sdp`.
pub fn verify_fp_sig(sdp: &str, fp_sig: &str, session: &str, role: &str, peer_key: &str) -> bool {
    let (Some(fingerprint), Some(sig)) = (fingerprint_of(sdp), b64::decode(fp_sig)) else {
        return false;
    };
    crate::hub::verify(peer_key, &fingerprint_message(session, role, &fingerprint), &sig)
}

#[cfg(test)]
mod tests {
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
}
