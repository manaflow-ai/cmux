//! What acpmux does not do on Windows yet. The Windows port lands in steps:
//! the first one makes the crate build there (and CI keeps it building); the
//! daemon's socket (`cmux::local_socket`), its lock (`LockFileEx`), its start
//! (CreateProcess with a handle list), owner-only ACLs and agent process
//! groups (job objects) come in later landings. Until then each of them
//! answers with [`unsupported`]. Unix builds do not compile this module.

/// The error a Windows build gives for `what`.
pub(crate) fn unsupported(what: &str) -> anyhow::Error {
    anyhow::anyhow!("{what} is not supported on Windows yet")
}
