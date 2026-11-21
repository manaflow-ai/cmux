//! One supervisor contract for cmux Remote and Cloud (hq `docs/design/remote-cloud-durability.md`
//! 4.1 and 4.2). acpmux's daemon service and `cmux host run` on a Cloud VM decide the same way:
//!
//! - [`record`]: an owner record `{pid, startTime, pgid, bootId, epoch, argv}`, written by
//!   tmp-then-rename before the thing serves. "Same process" is always decided from it
//!   ([`identity::check`]), never from a pid alone (F7).
//! - [`decide`]: restart only on proof (the process is gone by its recorded identity, or the
//!   progress probe failed on every look for the whole bound), never on wall-clock time alone
//!   (F8). The supervisor is the only actor that decides.
//! - [`intent`]: a stop someone meant is written down first and never respawns (F17).
//! - [`budget`]: a persisted per-day ledger of stops and their causes; above the budget the
//!   state is `restart-budget-exceeded`, with the causes, on the health the thing serves.
//! - [`death`]: on death, one event names what the dead thing owned.
//! - [`ends`]: for a process a service manager restarts, the end it wrote for itself, and the
//!   death of one that wrote none, settled once at the next start.
//! - [`swap`]: make-before-break replacement; a new one that fails readiness is dropped and the
//!   old one keeps serving (F9, F10).
//! - [`supervisor`]: `Supervisor::run(spec)`, the whole loop for a process nothing else
//!   supervises.

pub mod budget;
pub mod death;
pub mod decide;
pub mod ends;
pub mod identity;
pub mod intent;
pub mod record;
pub mod supervisor;
pub mod swap;

pub use budget::{Budget, BudgetState, StopCause};
pub use decide::{Decision, Progress};
pub use identity::{Identity, Liveness};
pub use record::OwnerRecord;
pub use supervisor::{Cmd, Ended, Files, Health, Probe, Spec, Supervisor};
pub use swap::{Swap, Swapped, make_before_break};
