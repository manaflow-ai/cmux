//! acpmux pairing tickets (`pairing::Ticket::decode`): the `cmxt1.` text a
//! person pastes from another machine, and the role names
//! (`pairing::Role::parse`) the CLI reads.
//!
//! Invariant past "no panic": a ticket that decodes encodes to one that
//! decodes to the same ticket (when the encoding fits the length cap).
#![no_main]

use acpmux::pairing::{Role, Ticket};
use libfuzzer_sys::fuzz_target;

/// The longest ticket `Ticket::decode` reads (`MAX_TICKET_BYTES`).
const MAX_TICKET_BYTES: usize = 2048;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else { return };
    let _ = Role::parse(text);
    let Ok(ticket) = Ticket::decode(text) else { return };
    let encoded = ticket.encode();
    if encoded.len() > MAX_TICKET_BYTES {
        return;
    }
    assert_eq!(Ticket::decode(&encoded), Ok(ticket), "a ticket does not survive its encoding");
});
