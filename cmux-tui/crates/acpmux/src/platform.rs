//! What acpmux does not do on Windows yet. The Windows port lands in steps:
//! the crate builds there (CI keeps it building), and the daemon socket
//! (`cmux::local_socket`), its start lock (LockFileEx) and random tokens
//! work. The detached start (CreateProcess with a handle list), owner-only
//! ACLs, the router's admin socket and agent process groups (job objects)
//! come in later landings. Until then each of them answers with
//! [`unsupported`]. Unix builds do not compile this module.

/// The error a Windows build gives for `what`.
pub(crate) fn unsupported(what: &str) -> anyhow::Error {
    anyhow::anyhow!("{what} is not supported on Windows yet")
}
