//! How the previous owner ended, for a supervised process that a service manager restarts
//! (launchd, systemd) rather than [`crate::Supervisor::run`]. A process that stops by itself
//! writes its end first ([`mark`]: a meant stop, an update's handover, a self-stop for a
//! repair). At the next start, a previous owner that wrote none and is gone by its recorded
//! identity died: a crash, a kill, a power loss ([`settle_previous`]). Each end is counted once
//! in the budget, and a death gets its event.

use serde::{Deserialize, Serialize};

use crate::budget::{BudgetState, StopCause, now_ms};
use crate::death::{self, Death};
use crate::identity::Liveness;
use crate::record::{self, OwnerRecord, Writer};
use crate::supervisor::Files;

/// The end an owner wrote for itself.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EndMark {
    pub epoch: u64,
    pub cause: StopCause,
    pub at_ms: u64,
}

/// Write the end of the owner of `epoch` and count it.
pub fn mark(
    files: &Files,
    epoch: u64,
    cause: StopCause,
    write: Writer<'_>,
) -> std::io::Result<BudgetState> {
    let at_ms = now_ms();
    let end = EndMark { epoch, cause: cause.clone(), at_ms };
    write(&files.end, &serde_json::to_vec(&end).map_err(std::io::Error::other)?)?;
    files.budget.record_with(cause, at_ms, write)
}

/// The end the owner of the record wrote, if it wrote one for its epoch.
pub fn read_mark(files: &Files) -> Option<EndMark> {
    serde_json::from_slice(&std::fs::read(&files.end).ok()?).ok()
}

/// What a start found about the owner before it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Previous {
    /// No record: the first start here.
    None,
    /// It wrote its end.
    Ended(OwnerRecord, EndMark),
    /// It wrote none and is gone: counted as a death, its event written.
    Died(Death),
    /// It still runs (this start lost a race, or the record is this process's own), or its
    /// liveness cannot be told: nothing is counted.
    Running(OwnerRecord),
}

/// At a start, before this process writes its own record: settle how the previous owner
/// ended. `owned` names what it owned, for the death event.
pub fn settle_previous(files: &Files, owned: &[String], write: Writer<'_>) -> Previous {
    let Some(prev) = record::load(&files.owner).record().cloned() else { return Previous::None };
    if let Some(end) = read_mark(files).filter(|m| m.epoch == prev.epoch) {
        return Previous::Ended(prev, end);
    }
    if prev.is_current() || prev.liveness() != Liveness::Dead {
        return Previous::Running(prev);
    }
    let cause = StopCause::Died(format!(
        "pid {} (epoch {}) ended without writing its end: a crash, a kill or a power loss",
        prev.pid, prev.epoch
    ));
    let at_ms = now_ms();
    let death = Death {
        name: files.name.clone(),
        owner: prev.clone(),
        cause: cause.clone(),
        owned: owned.to_vec(),
        at_ms,
    };
    let _ = files.budget.record_with(cause.clone(), at_ms, write);
    // Marked, so a second start that races this one does not count the same death again.
    let end = EndMark { epoch: prev.epoch, cause, at_ms };
    if let Ok(bytes) = serde_json::to_vec(&end) {
        let _ = write(&files.end, &bytes);
    }
    let _ = death::append(&files.deaths, &death);
    Previous::Died(death)
}

#[cfg(test)]
#[cfg(target_os = "linux")]
mod tests {
    use super::*;

    #[test]
    fn a_marked_end_counts_once_and_a_missing_one_is_a_death_once() {
        let dir = std::env::temp_dir().join(format!("supervise-ends-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let files = Files::new(&dir, "daemon", 5);
        assert_eq!(settle_previous(&files, &[], &record::write_file), Previous::None);

        // A child stands in for the previous daemon: recorded, then killed with no end.
        let mut child = std::process::Command::new("sleep").arg("30").spawn().unwrap();
        let who = crate::identity::of(child.id()).unwrap();
        let rec = OwnerRecord::new(who, None, vec!["sleep".into()]);
        record::store(&files.owner, &rec).unwrap();
        assert!(matches!(settle_previous(&files, &[], &record::write_file), Previous::Running(_)));
        child.kill().unwrap();
        child.wait().unwrap();
        let owned = vec!["sessions".to_owned()];
        match settle_previous(&files, &owned, &record::write_file) {
            Previous::Died(d) => assert_eq!((d.owner.epoch, d.owned), (1, owned.clone())),
            other => panic!("{other:?}"),
        }
        // Settled once: a second look reads the end it wrote.
        assert!(matches!(
            settle_previous(&files, &owned, &record::write_file),
            Previous::Ended(..)
        ));
        assert_eq!(files.budget.today().faults, 1);
        assert_eq!(death::read_all(&files.deaths).len(), 1);

        // This process takes over, then stops on purpose.
        let me = record::claim_current_with(&files.owner, &record::write_file).unwrap();
        mark(&files, me.epoch, StopCause::Intentional("shutdown".into()), &record::write_file)
            .unwrap();
        match settle_previous(&files, &owned, &record::write_file) {
            Previous::Ended(r, m) => {
                assert_eq!(r.epoch, 2);
                assert_eq!(m.cause, StopCause::Intentional("shutdown".into()));
            }
            other => panic!("{other:?}"),
        }
        let ledger = files.budget.today();
        assert_eq!((ledger.stops, ledger.faults), (2, 1));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
