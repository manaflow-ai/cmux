//! The connection side of `cmux link` (plans/cmux-next/transport.md 12c,
//! plans/cmux-next/finder.md 3 to 5).
//!
//! `cmux link` is the single writer of connection records (`conn_…`): what a
//! connection points at, which credential it uses, the state of the host key
//! and the state of the path.
//!
//! - [`conn`]: the `conn_…` records, a pure reducer over typed ops with
//!   idempotency keys, and the durable store that commits them.
//! - [`host_key`]: fingerprints, the link-owned known-hosts file and the
//!   offered-key observer. A changed key is a hard stop.
//! - [`ssh_args`]: the validated OpenSSH argv builder.

pub mod conn;
pub mod host_key;
pub mod ids;
pub mod ssh_args;
