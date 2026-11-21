//! The machine's vault egress proxy.
//!
//! The daemon gives each agent `NAME=cmux-secret://NAME` instead of a vault
//! value, and `HTTPS_PROXY` pointing here. An agent (or a tool it runs) that
//! sends the placeholder in a request header gets the real value put in, but
//! only on a connection to a host that secret allows:
//!
//! - A `CONNECT` to a host some secret allows is intercepted: the client
//!   handshakes with a leaf for that host signed by [`Authority`], a CA that
//!   lives in this process's memory and that only agent processes are told to
//!   trust (`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE` and friends). Upstream is a
//!   normal TLS connection verified against the OS trust store. In each
//!   request, `cmux-secret://NAME` in a header value (Basic credentials too)
//!   becomes NAME's value when NAME allows the host. The URL, the body and
//!   every other host never see a value.
//! - Every other `CONNECT` is a blind tunnel: no interception, so the
//!   placeholder goes out unchanged and pinned clients keep working.
//! - Plain HTTP is not served (the daemon sets only `HTTPS_PROXY`).
//!
//! A request whose `Host` names another authority than its `CONNECT` is
//! refused (421), so a shared front end cannot route a value elsewhere.
//! Destinations are resolved here and loopback, link-local, unspecified and
//! multicast addresses are refused, so a rebound name cannot point a value at
//! a local service.
//!
//! Every substitution is logged as `vault.egress_substituted` with the secret's
//! name and the host, never a value.

mod ca;
mod proxy;
mod substitute;

pub use ca::Authority;
pub use proxy::{Config, Resolver, bind, serve, upstream_tls_from_os, upstream_tls_with_roots};
pub use substitute::{HostPattern, PLACEHOLDER_PREFIX, Policy, Secret, placeholder};
