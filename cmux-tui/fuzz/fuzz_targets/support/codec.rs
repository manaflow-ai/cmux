//! The property every task-020 host codec target checks: bad bytes give an
//! error, never a panic; what the decoder accepts its encoder writes again,
//! and that encoding is a fixed point (decoding and re-encoding it gives the
//! same bytes).

use cmux_tui_core::fuzz_entry::Decoded;

/// Checks `decoded` and returns the canonical bytes it accepted, if any.
pub fn assert_canonical(
    decoded: Decoded,
    decode_again: impl Fn(&[u8]) -> Decoded,
) -> Option<Vec<u8>> {
    let canonical = match decoded {
        Decoded::Rejected(_) => return None,
        Decoded::Unencodable(error) => {
            panic!("the decoder accepted a value its encoder refuses: {error:#}")
        }
        Decoded::Accepted(canonical) => canonical,
    };
    match decode_again(&canonical) {
        Decoded::Accepted(again) => {
            assert!(again == canonical, "the canonical encoding is not a fixed point");
        }
        Decoded::Rejected(error) => panic!("the decoder refuses its own encoding: {error:#}"),
        Decoded::Unencodable(error) => {
            panic!("the decoder's own encoding decodes to an unencodable value: {error:#}")
        }
    }
    Some(canonical)
}
