//! Provenance keys (`prompt_provenance.rs`) that the host's sender token (`sender_token.rs`)
//! reads and sets.

/// What `from` says in `prompt_provenance::named_sender`: the sender named itself and is no
/// address here.
pub const NAMED_SENDER: &str = "fromAgent";

/// Whether the daemon itself bound the sender's identity (`true`: a caller-proven session, the
/// hub's own prompt), or the sender only claimed it (`false`: a name, a peer's label, a
/// provenance a client sent). Set by the daemon only: a client's own `verified` is never read
/// (`prompt_provenance::of` keeps only its listed fields), and the person's prompt carries none
/// (see `prompt_provenance::ORIGIN`).
pub const VERIFIED: &str = "verified";

/// The provenance kind of a tool's notice (`prompt_provenance::notice`).
pub const NOTICE_KIND: &str = "notice";
