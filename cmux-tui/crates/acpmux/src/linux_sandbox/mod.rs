//! Linux remote chains enforce `sandbox/remote-chain.sb`, parsed by `rules`.
//! bwrap isolates mounts, PIDs and networking; seccomp and the user-notify
//! supervisor enforce persistence names and mutations. The proxy restricts
//! outbound ports and destinations; a dedicated forwarder allows only the
//! configured IPv4 loopback API port. Probe and session canary must both pass.
pub(crate) mod bwrap;
pub(crate) mod init;
pub(crate) mod keeper;
pub(crate) mod lookup;
pub(crate) mod proxy;
pub(crate) mod rules;
pub(crate) mod seccomp;
pub(crate) mod supervisor;
