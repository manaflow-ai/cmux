//! cmux browser sync, RFD 0125 D8 ("Sync across the person's cmux browsers and machines"), order step 2.
//!
//! Two halves, with different trust:
//!
//! - [`records`]: the profile list (name, colour, icon) and the space and workspace bindings. The RFD lets the
//!   server read these, so they travel as plain JSON records over the cmux account
//!   (cmux-platform `POST /v1/sync/browser/records`). Each record is last writer wins per id, a deletion is a
//!   tombstone, and [`records::sync_once`] is one push and pull. The daemon runs it only when the
//!   `browser.sync.profiles` setting is on ([`settings`]; off by default).
//! - [`keys`] and [`envelope`]: open tabs sync end to end encrypted. A profile key seals each record
//!   ([`envelope::Envelope`]); the key is wrapped to each device's X25519 key and to a recovery key shown once.
//!   Whether the server may also hold an escrowed copy is Leo's call (RFD item [irreversible] 2), so it is a
//!   switch, [`keys::EscrowPolicy`], whose default is [`keys::EscrowPolicy::None`]. Nothing here stores tabs on a
//!   server yet.

pub mod envelope;
pub mod keys;
pub mod records;
pub mod settings;
