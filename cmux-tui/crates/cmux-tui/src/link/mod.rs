//! `cmux link`: the per-user process that owns this machine's overlay
//! endpoint (plans/cmux-next/transport.md 3 and 12a). Slice 1: direct paths
//! to paired peers only, no relay.

mod dial;
mod inbound;
mod lines;

#[cfg(test)]
mod tests;
