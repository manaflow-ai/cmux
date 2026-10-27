//! `cmux.rd/1` viewer feedback (`Feedback::decode`). The decoder accepts more
//! arrivals and NACKs than the encoder writes (`MAX_ARRIVALS`,
//! `MAX_NACK_FRAMES`, `MAX_NACK_INDEXES`); within those limits a decoded
//! message encodes back to the same bytes.
#![no_main]

use cmux_rd_proto::{Feedback, MAX_ARRIVALS, MAX_NACK_FRAMES, MAX_NACK_INDEXES};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(feedback) = Feedback::decode(data) else { return };
    let within_limits = feedback.arrivals.len() <= MAX_ARRIVALS
        && feedback.nacks.len() <= MAX_NACK_FRAMES
        && feedback.nacks.iter().all(|nack| nack.indexes.len() <= MAX_NACK_INDEXES);
    let encoded = feedback.encode();
    if within_limits {
        assert_eq!(encoded, data);
    } else {
        // The encoder truncates to its limits; what it writes still decodes.
        assert!(Feedback::decode(&encoded).is_ok());
    }
});
