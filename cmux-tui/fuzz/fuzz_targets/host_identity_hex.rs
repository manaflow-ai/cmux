//! A terminal-host record's hex identities (`decode_hex_array` and the
//! canonical-record `decode_lower_hex_array`,
//! terminal_host_runtime/shared/codec.rs). The first byte's low bit picks the
//! lowercase-only decoder; the rest is the text. An accepted identity
//! re-encodes to the text: exactly for the lowercase decoder, up to ASCII case
//! for the other.

#![no_main]

#[path = "support/codec.rs"]
mod codec;

use cmux_tui_core::fuzz_entry::{Decoded, host_identity_hex};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Some((&mode, text)) = data.split_first() else {
        return;
    };
    let Ok(text) = std::str::from_utf8(text) else {
        return;
    };
    let lowercase_only = mode & 1 != 0;
    let decode = |text: &[u8]| match std::str::from_utf8(text) {
        Ok(text) => host_identity_hex(text, lowercase_only),
        Err(error) => Decoded::Rejected(error.into()),
    };
    let Some(canonical) = codec::assert_canonical(host_identity_hex(text, lowercase_only), decode)
    else {
        return;
    };
    if lowercase_only {
        assert!(canonical == text.as_bytes(), "a canonical identity is not its own hex");
    } else {
        assert!(canonical.eq_ignore_ascii_case(text.as_bytes()), "an identity is not its hex");
    }
});
