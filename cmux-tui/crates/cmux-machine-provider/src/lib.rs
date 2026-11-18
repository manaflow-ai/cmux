//! Labs prototype, off by default (`labs.gcpMachineProvider`): one
//! provider-neutral machine lifecycle contract
//! (cmuxterm-hq `plans/cloud-roadmap/gcp-self-hosting-design.md`), the
//! idempotency ledger every lifecycle call goes through, a fake provider, and a
//! Compute Engine adapter that runs in the user's own GCP project.
//!
//! The adapter runs on the user's machine only: the access token is read from
//! a file descriptor the caller opens, handed to the HTTP client on its stdin,
//! and never written to argv, the environment, a receipt, a log or the ledger.
//! The VM it creates gets no provider credential and no public address.

pub mod conformance;
pub mod contract;
pub mod fake;
pub mod gcp;
pub mod labs;
pub mod ledger;

pub use contract::{
    CostEstimate, CreateSpec, IdempotencyKey, MachineProvider, MachineState, Op, ProviderError,
    Receipt, Request,
};
pub use fake::FakeProvider;
pub use gcp::{AccessToken, CurlTransport, GcpProvider, Transport, TransportError};
pub use ledger::{Ledger, Outcome};
