//! Team VM reconciler (team-host role of `cmux`, plans/cmux-next/team-vm-plan.md S4).
//!
//! `TeamDO` owns members, Linux names, UID and GID blocks, the node tree and role grants. The
//! reconciler is a projection: it compiles a directory snapshot into Linux users and groups (with
//! the membership closure), node directories (setgid, access ACL = default ACL), org and person
//! memory, the mailbox modes and homes, then plans the difference with the machine and applies it.
//! A second run is a no-op; drift is reverted; a member name that a system account (UID below
//! 20000) already has is refused and reported, never taken over.
//!
//! Pure parts: [`directory`], [`desired`], [`acl`], [`observed`], [`plan`]. I/O: [`host`].

pub mod acl;
pub mod desired;
pub mod directory;
pub mod host;
pub mod observed;
pub mod plan;

pub use desired::{Desired, Layout, compile};
pub use directory::{Directory, Refusal, validate};
pub use host::{Accounts, Report, System, reconcile};
pub use plan::{Action, Plan, plan};
