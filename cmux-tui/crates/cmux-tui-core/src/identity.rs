//! Durable UUID identities used across daemon and frontend lifetimes.

use std::fmt;
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

macro_rules! uuid_identity {
    ($name:ident) => {
        #[derive(
            Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
        )]
        #[serde(transparent)]
        pub struct $name(Uuid);

        impl $name {
            pub fn new() -> Self {
                Self(Uuid::new_v4())
            }

            pub fn as_uuid(self) -> Uuid {
                self.0
            }
        }

        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(formatter)
            }
        }

        impl FromStr for $name {
            type Err = uuid::Error;

            fn from_str(value: &str) -> Result<Self, Self::Err> {
                Uuid::parse_str(value).map(Self)
            }
        }
    };
}

uuid_identity!(DaemonInstanceId);
uuid_identity!(SessionId);
uuid_identity!(PresentationId);
uuid_identity!(WorkspaceUuid);
uuid_identity!(ScreenUuid);
uuid_identity!(PaneUuid);
uuid_identity!(SurfaceUuid);

/// One allocation seam for every daemon-owned canonical entity. Legacy
/// numeric IDs remain process-local compatibility handles; UUIDs are the
/// stable identity carried by snapshots and revisioned deltas.
pub(crate) struct EntityIdentityAllocator {
    next_legacy_id: AtomicU64,
}

impl EntityIdentityAllocator {
    pub(crate) fn new() -> Self {
        Self { next_legacy_id: AtomicU64::new(1) }
    }

    fn next_legacy_id(&self) -> u64 {
        self.next_legacy_id.fetch_add(1, Ordering::Relaxed)
    }

    pub(crate) fn workspace(&self) -> (u64, WorkspaceUuid) {
        (self.next_legacy_id(), WorkspaceUuid::new())
    }

    pub(crate) fn screen(&self) -> (u64, ScreenUuid) {
        (self.next_legacy_id(), ScreenUuid::new())
    }

    pub(crate) fn pane(&self) -> (u64, PaneUuid) {
        (self.next_legacy_id(), PaneUuid::new())
    }

    pub(crate) fn surface(&self) -> (u64, SurfaceUuid) {
        (self.next_legacy_id(), SurfaceUuid::new())
    }
}
