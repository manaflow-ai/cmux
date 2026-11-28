//! A phone's ACP chat over a Cloud machine's daemon carrier, shared by the two
//! places that serve it:
//!
//! - hostd on the person's Mac (`cmux-mobile-host` `cloud-acpmux`), which
//!   relays the phone to the machine through the Mac's own link, and
//! - the Cloud machine's own link (`cmux-tui` `link::phone_chat`, the
//!   `phone_chat` service), which the phone dials directly with the Mac off
//!   (RFD 0135 gate 4).
//!
//! Both connect to the machine daemon's local Unix socket, run [`handshake`]
//! (which marks the connection as a mobile client, so the daemon holds it to
//! the phone floor, `cmux-tui-core` `server/phone_carrier.rs`), then pump
//! newline JSON through one [`Adapter`].

mod adapter;
mod carrier;

pub use adapter::{Adapter, Effects};
pub use carrier::{
    AGENT_SESSION_TABS, CLOUD_MOBILE_CHAT, CONVERSATION_TABS, Fault, MAX_NATIVE_LINE, handshake,
    read_line,
};
