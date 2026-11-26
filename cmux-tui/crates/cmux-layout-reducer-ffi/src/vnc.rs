//! `cmux-vnc`'s rules for Packages/Shared/CmuxVNC over the JSON channel
//! (`vnc_*`): addresses, keysyms, the security choice, the version banner and
//! the authentication responses. The ops live in `cmux_vnc::json`, which iOS
//! reaches over cmux-mobile-link-ffi's `vnc_json`; this is only the Mac's door.

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(cmux_vnc::json::OPERATION_PREFIX.as_bytes())
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let answer = cmux_vnc::json::respond(operation, request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_mac_door_answers_a_vnc_op() {
        assert!(super::handles(b"vnc_version"));
        let answer = super::respond(b"vnc_version", br#"{"banner":"UkZCIDAwMy4wMDgK"}"#).unwrap();
        let answer: serde_json::Value = serde_json::from_slice(&answer).unwrap();
        assert_eq!(answer["minor"], 8);
    }
}
