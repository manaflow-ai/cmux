//! The cmux.rd/1 offer and answer documents a hub session's signaling carries (the Mac's
//! `MacScreenRdDocument`), the fingerprint signature both sides put on them (`fpSig`,
//! PROTOCOL.md Session flow 5), and the session's ICE servers as `cmux-rd serve` takes them.
//!
//! The documents, the signed bytes and the ICE servers live in `cmux_rd_link::doc`, so a
//! viewer without the hub client (the iPhone's) shares them; this module re-exports them and
//! adds the signature check, which needs the device key code.

use crate::b64;

pub use cmux_rd_link::doc::{
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

    #[test]
    fn the_documents_are_the_links() {
        // One definition: the hub's names are the link crate's types.
        let doc: cmux_rd_link::doc::RdDocument =
            RdDocument { key: KEY.into(), max_width: Some(1280), ..RdDocument::default() };
        assert_eq!(RdDocument::parse(&doc.text()), Some(doc));
    }
}
