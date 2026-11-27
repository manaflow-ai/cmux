//! The cmux.rd/1 offer and answer documents a hub session's signaling carries and the session's
//! ICE servers (cmux-rd-proto's `rd_doc`, shared with the Mac app), and the fingerprint signature
//! both sides put on them (`fpSig`, PROTOCOL.md Session flow 5).

use crate::b64;
pub use cmux_rd_proto::rd_doc::{
    fingerprint_message, fingerprint_of, is_relayed, servers, udp_only, RdDocument, Turn,
    TurnTransport, HEADER, KEY_PREFIX,
};

/// Whether `fp_sig` (base64 raw r||s) is `peer_key`'s signature of `role`'s fingerprint in `sdp`.
pub fn verify_fp_sig(sdp: &str, fp_sig: &str, session: &str, role: &str, peer_key: &str) -> bool {
    let (Some(fingerprint), Some(sig)) = (fingerprint_of(sdp), b64::decode(fp_sig)) else {
        return false;
    };
    crate::hub::verify(peer_key, &fingerprint_message(session, role, &fingerprint), &sig)
}

#[cfg(test)]
#[path = "rd_doc_tests.rs"]
mod tests;
