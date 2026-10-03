//! The connection side of `cmux link` (plans/cmux-next/transport.md 12c,
//! plans/cmux-next/finder.md 3 to 5).
//!
//! `cmux link` is the single writer of connection records (`conn_…`): what a
//! connection points at, which credential it uses, the state of the host key
//! and the state of the path. This crate holds that record store and the
//! plain SSH connection kind, which reaches hosts without a cmux daemon:
//!
//! - [`conn`]: the `conn_…` records, a pure reducer over typed ops with
//!   idempotency keys, and the durable store that commits them.
//! - [`host_key`]: fingerprints, the link-owned known-hosts file and the
//!   offered-key observer. A changed key is a hard stop.
//! - [`ssh`]: the system OpenSSH client, started through [`ssh_args`].
//! - [`sftp`]: a small SFTP v3 client over `ssh -s sftp` stdio.
//! - [`fs`]: the Finder `fs.*` operations on a root of an SFTP host.
//! - [`bulk`] and [`job`]: credit-window byte channels and copy jobs.

pub mod bulk;
pub mod conn;
pub mod fs;
pub mod host_key;
pub mod ids;
pub mod job;
pub mod sftp;
pub mod ssh;
pub mod ssh_args;
#[cfg(test)]
mod test_support;
