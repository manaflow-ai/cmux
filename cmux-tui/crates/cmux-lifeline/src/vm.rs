//! A VM handle is consumed at each lifecycle edge.
//!
//! These are local operation capabilities, not a lock on a remote VM. An adapter
//! must still handle a server conflict, and must only complete an edge after the
//! corresponding authoritative response. A request accepted for asynchronous
//! work enters an intermediate state, never the completed state.
//!
//! Provider `running` is deliberately distinct from `Ready`: the agent's
//! readiness handshake must succeed before an attach can be constructed.
//!
//! ```
//! use cmux_lifeline::vm::{Vm, Unallocated};
//! let vm = Vm::<Unallocated, _>::new("request-key").provision();
//! let vm = vm.running().ready().attach();
//! let vm = vm.pause().paused().resume().running().ready();
//! let deleted = vm.delete().deleted();
//! assert_eq!(*deleted.payload(), "request-key");
//! ```
//!
//! A VM cannot attach before readiness:
//! ```compile_fail
//! use cmux_lifeline::vm::{Vm, Unallocated};
//! Vm::<Unallocated, _>::new("vm").provision().running().attach();
//! ```
//! A deleted VM has no pause operation:
//! ```compile_fail
//! use cmux_lifeline::vm::{Vm, Unallocated};
//! Vm::<Unallocated, _>::new("vm").provision().delete().deleted().pause();
//! ```
//! A transition consumes the old capability:
//! ```compile_fail
//! use cmux_lifeline::vm::{Vm, Unallocated};
//! let vm = Vm::<Unallocated, _>::new("vm").provision().running();
//! let pausing = vm.pause();
//! let deleting = vm.delete();
//! ```

use std::marker::PhantomData;

use serde::{Deserialize, Serialize};

/// The lifecycle vocabulary at the wire boundary. Unknown words are errors;
/// `unknown` is an explicit provider observation and grants no live capability.
/// Pool ownership and agent readiness are local protocol states, never wire power
/// states: neither can be granted by a provider claiming `ready` or `attached`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Provisioning,
    Running,
    Pausing,
    Paused,
    Starting,
    Stopped,
    Deleting,
    #[serde(alias = "deleted")]
    Destroyed,
    Failed,
    Unknown,
}

impl Status {
    /// Every provider observation accepted at the lifecycle boundary.
    pub const ALL: [Self; 10] = [
        Self::Provisioning,
        Self::Running,
        Self::Failed,
        Self::Paused,
        Self::Destroyed,
        Self::Unknown,
        Self::Pausing,
        Self::Starting,
        Self::Deleting,
        Self::Stopped,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Provisioning => "provisioning",
            Self::Running => "running",
            Self::Failed => "failed",
            Self::Paused => "paused",
            Self::Destroyed => "destroyed",
            Self::Unknown => "unknown",
            Self::Pausing => "pausing",
            Self::Starting => "starting",
            Self::Deleting => "deleting",
            Self::Stopped => "stopped",
        }
    }

    /// Compatibility for display-only records. Operation boundaries use
    /// `parse` or serde instead, so malformed observations grant no capability.
    pub fn from_word(word: &str) -> Self {
        word.parse().unwrap_or(Self::Unknown)
    }

    pub fn is_live(self) -> bool {
        matches!(self, Self::Running | Self::Provisioning | Self::Starting)
    }

    pub fn is_changing(self) -> bool {
        matches!(self, Self::Pausing | Self::Starting | Self::Deleting)
    }
}

/// An unrecognized provider status. The raw value is deliberately not retained.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InvalidStatus;

impl std::fmt::Display for InvalidStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("unrecognized VM lifecycle state")
    }
}
impl std::error::Error for InvalidStatus {}

impl std::str::FromStr for Status {
    type Err = InvalidStatus;

    fn from_str(word: &str) -> Result<Self, Self::Err> {
        if word == "deleted" {
            return Ok(Self::Destroyed);
        }
        Self::ALL.into_iter().find(|status| status.as_str() == word).ok_or(InvalidStatus)
    }
}

/// A capability for `T` in state `S`. It is neither cloneable nor deserializable:
/// external observations enter through [`Status::bind`], not a phantom cast.
#[derive(Debug)]
#[must_use = "keep the next lifecycle capability until the operation ends"]
pub struct Vm<S, T> {
    payload: T,
    state: PhantomData<S>,
}

impl<S, T> Vm<S, T> {
    /// The identity or transport owned by this capability.
    pub fn payload(&self) -> &T {
        &self.payload
    }

    /// Mutate the owned transport without changing its lifecycle capability.
    pub fn payload_mut(&mut self) -> &mut T {
        &mut self.payload
    }

    fn next<N>(self) -> Vm<N, T> {
        Vm { payload: self.payload, state: PhantomData }
    }
}

macro_rules! states {
    ($($state:ident),+ $(,)?) => {$(
        #[doc = concat!("The ", stringify!($state), " lifecycle state.")]
        #[derive(Debug)]
        pub struct $state;
    )+};
}

states!(
    Unallocated,
    Provisioning,
    Preclaimed,
    Claimed,
    Running,
    Ready,
    Attached,
    Pausing,
    Paused,
    Starting,
    Stopped,
    Deleting,
    Deleted,
    Failed,
    Unknown,
);

impl<T> Vm<Unallocated, T> {
    /// Begin an allocation intent. `payload` should retain its idempotency key.
    pub fn new(payload: T) -> Self {
        Self { payload, state: PhantomData }
    }

    /// The create request was accepted; the VM is not ready yet.
    pub fn provision(self) -> Vm<Provisioning, T> {
        self.next()
    }
}

impl<T> Vm<Running, T> {
    /// Bind an authoritative running observation to its subject. A connected
    /// transport may also establish this fact, but must still identify the agent
    /// before granting readiness. This does not allocate or resume a VM.
    pub fn observed_running(payload: T) -> Self {
        Self { payload, state: PhantomData }
    }
}

macro_rules! edge {
    ($from:ident, $method:ident, $to:ident, $doc:literal) => {
        impl<T> Vm<$from, T> {
            #[doc = $doc]
            pub fn $method(self) -> Vm<$to, T> {
                self.next()
            }
        }
    };
}

edge!(Provisioning, preclaim, Preclaimed, "The pool reserved this allocation for the caller.");
edge!(Preclaimed, claim, Claimed, "The reservation was committed to the caller.");
edge!(Provisioning, running, Running, "The provider observed a running VM (without a pool claim).");
edge!(Claimed, running, Running, "The claimed VM is running according to the provider.");
edge!(Starting, running, Running, "The resumed VM is running according to the provider.");
edge!(Running, ready, Ready, "The agent readiness handshake succeeded for this VM.");
edge!(Ready, attach, Attached, "The attach handshake succeeded.");
edge!(Attached, detach, Ready, "The attachment ended; the agent remains ready.");
edge!(Running, pause, Pausing, "Pause was accepted; it has not completed yet.");
edge!(Ready, pause, Pausing, "Pause was accepted; readiness is consumed.");
edge!(Attached, pause, Pausing, "Pause was accepted; the attachment is no longer usable.");
edge!(Pausing, paused, Paused, "The provider confirmed that the VM is paused.");
edge!(Paused, resume, Starting, "Resume was accepted; readiness must be established again.");
edge!(Stopped, start, Starting, "Start was accepted; readiness must be established again.");
edge!(Deleting, deleted, Deleted, "The provider confirmed deletion.");

macro_rules! deletable {
    ($($state:ident),+ $(,)?) => {$(
        edge!($state, delete, Deleting, "Deletion was accepted; the allocation still needs a terminal receipt.");
    )+};
}

deletable!(
    Provisioning,
    Preclaimed,
    Claimed,
    Running,
    Ready,
    Attached,
    Pausing,
    Paused,
    Starting,
    Stopped,
    Failed,
    Unknown
);

macro_rules! fallible {
    ($($state:ident),+ $(,)?) => {$(
        edge!($state, failed, Failed, "The operation failed authoritatively; retain the allocation for cleanup.");
    )+};
}

fallible!(Provisioning, Preclaimed, Claimed, Running, Ready, Attached, Pausing, Starting, Deleting);

/// A parsed observation. Match once at the boundary to obtain a typed handle;
/// subsequent steps accept only the capability they can operate on.
#[derive(Debug)]
pub enum Observed<T> {
    Provisioning(Vm<Provisioning, T>),
    Running(Vm<Running, T>),
    Pausing(Vm<Pausing, T>),
    Paused(Vm<Paused, T>),
    Starting(Vm<Starting, T>),
    Stopped(Vm<Stopped, T>),
    Deleting(Vm<Deleting, T>),
    Deleted(Vm<Deleted, T>),
    Failed(Vm<Failed, T>),
    Unknown(Vm<Unknown, T>),
}

impl Status {
    /// Bind an authoritative observation to its subject. A provider's `running`
    /// alone never grants an attach capability.
    pub fn bind<T>(self, payload: T) -> Observed<T> {
        let vm = Vm::<Unallocated, T>::new(payload);
        match self {
            Self::Provisioning => Observed::Provisioning(vm.next()),
            Self::Running => Observed::Running(vm.next()),
            Self::Pausing => Observed::Pausing(vm.next()),
            Self::Paused => Observed::Paused(vm.next()),
            Self::Starting => Observed::Starting(vm.next()),
            Self::Stopped => Observed::Stopped(vm.next()),
            Self::Deleting => Observed::Deleting(vm.next()),
            Self::Destroyed => Observed::Deleted(vm.next()),
            Self::Failed => Observed::Failed(vm.next()),
            Self::Unknown => Observed::Unknown(vm.next()),
        }
    }
}

#[cfg(test)]
mod tests;
