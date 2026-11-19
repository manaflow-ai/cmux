//! Try on: apply a customization for a while, so trying something costs
//! nothing. A try-on is an applied generation with an end time. Unless
//! someone keeps it, it reverts to the setup before it once the time is up.
//!
//! The record is a file (`try-on.json`), not a timer: whatever looks next
//! settles it ([`Customize::settle`]). A look can be any verb, the app's
//! start or the CLI's waiting child. So an app that quit, a machine that
//! slept or a laptop that rebooted mid-try still reverts at the first look
//! after the end time. [`Customize::run_try_on_timer`] is the one place
//! that waits. It sleeps until the end time, never polls, and returns once
//! no try-on is left.
//!
//! The rules, in order:
//! - **Keep** ends the try-on and leaves the generation applied.
//! - **Revert now**, or the end time, puts back what was applied before it.
//!   Hand edits made during the try-on are kept by number, as a discard
//!   keeps a draft.
//! - Applying or rolling back past the try-on generation counts as moving
//!   on, so the try-on ends where it is and reverts nothing.
//! - Trying on again before a try-on ends replaces it. The new one still
//!   reverts to the setup before the first, so trying three things and
//!   keeping none puts back what you started with.

use std::time::Duration;

use serde::Serialize;

use crate::profile::Profile;
use crate::store::{Kind, TryOn};
use crate::{Applied, Customize, Error, Restored};

/// How long a try-on lasts when no time is given.
pub const DEFAULT_TRY_ON_MINUTES: u32 = 10;
/// The longest try-on: a day. Past that it is not trying, it is using.
pub const MAX_TRY_ON_MINUTES: u32 = 24 * 60;

/// What a try-on started.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TriedOn {
    pub try_on: TryOn,
    pub applied: Applied,
    /// A try-on that was still running and was replaced by this one.
    pub replaced: Option<TryOn>,
}

/// How a try-on ended.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "outcome", rename_all = "kebab-case")]
pub enum Settled {
    /// The time ran out, or someone pressed Revert now: what was applied
    /// before it is back.
    Reverted { try_on: TryOn, restored: Restored },
    /// Someone pressed Keep: it stays applied.
    Kept { try_on: TryOn },
    /// Someone applied or rolled back past it: it ends where it is.
    Ended { try_on: TryOn },
}

impl Settled {
    pub fn try_on(&self) -> &TryOn {
        match self {
            Settled::Reverted { try_on, .. }
            | Settled::Kept { try_on }
            | Settled::Ended { try_on } => try_on,
        }
    }
}

/// The origin a try-on reverts under when its time runs out: cmux itself
/// putting back the person's own earlier setup.
const TIMER_ORIGIN: &str = "cmux";

impl Customize {
    /// Applies `profile` (or, with `None`, what is live now: the open
    /// preview) as a try-on that reverts by itself `duration_ms` from now.
    /// The profile is checked and validated as `use` checks it; one failure
    /// writes nothing.
    pub fn try_on(
        &self,
        profile: Option<&Profile>,
        duration_ms: u64,
        origin: &str,
        now_ms: u64,
    ) -> Result<TriedOn, Error> {
        if !(1_000..=u64::from(MAX_TRY_ON_MINUTES) * 60_000).contains(&duration_ms) {
            return Err(Error::TryOnTime);
        }
        // There is always a setup to revert to: the one before anything.
        self.ensure_baseline(now_ms)?;
        let _lock = self.store().lock()?;
        let running = self.live_try_on_locked()?;
        // The library as it was before the first try-on in a row, so a
        // revert puts back exactly that.
        let library = running
            .as_ref()
            .and_then(|running| running.library.clone())
            .or_else(|| self.library_mark());
        if let Some(profile) = profile {
            self.preview_profile_locked(profile, origin, now_ms)?;
        }
        // What it reverts to is read after the preview began: hand edits
        // found then were recorded as their own generation, and reverting
        // keeps them.
        let before = self.current_generation()?;
        let applied = self.apply_locked(None, origin, now_ms)?;
        if !applied.recorded {
            return Err(Error::NothingToTry);
        }
        let try_on = TryOn {
            generation: applied.generation.n,
            revert_to: running.as_ref().map_or(before, |running| running.revert_to),
            started_ms: now_ms,
            expires_ms: now_ms.saturating_add(duration_ms),
            label: applied.generation.label.clone(),
            origin: origin.to_owned(),
            library,
        };
        self.store().put_try_on(Some(&try_on))?;
        Ok(TriedOn { try_on, applied, replaced: running })
    }

    /// The running try-on, if any. Reads only; a try-on that was moved past
    /// reads as none.
    pub fn try_on_state(&self) -> Result<Option<TryOn>, Error> {
        let current = self.current_generation()?;
        Ok(self.store().try_on()?.filter(|try_on| Some(try_on.generation) == current))
    }

    /// Keep: the try-on's generation stays applied. `None` when nothing was
    /// being tried on.
    pub fn keep(&self) -> Result<Option<Settled>, Error> {
        let _lock = self.store().lock()?;
        let Some(try_on) = self.store().try_on()? else { return Ok(None) };
        self.store().put_try_on(None)?;
        if Some(try_on.generation) != self.current_generation()? {
            return Ok(Some(Settled::Ended { try_on }));
        }
        Ok(Some(Settled::Kept { try_on }))
    }

    /// Revert now: what was applied before the try-on is back. `None` when
    /// nothing was being tried on.
    pub fn revert_try_on(&self, origin: &str, now_ms: u64) -> Result<Option<Settled>, Error> {
        let _lock = self.store().lock()?;
        self.settle_locked(None, origin, now_ms)
    }

    /// Ends a try-on whose time is up (reverting it), or one that was moved
    /// past. `None` when there is none or it still runs. Every surface calls
    /// this before it looks, so a try-on reverts at the first look after its
    /// time even if nothing was running then.
    pub fn settle(&self, now_ms: u64) -> Result<Option<Settled>, Error> {
        if self.store().try_on()?.is_none() {
            return Ok(None);
        }
        let _lock = self.store().lock()?;
        self.settle_locked(Some(now_ms), TIMER_ORIGIN, now_ms)
    }

    /// Waits for the running try-on and settles it when its time is up.
    /// Returns once no try-on is left: kept, reverted, ended or never
    /// started. That is the stop condition. It sleeps until each end time
    /// and never polls. A try-on started meanwhile is waited for too, and a
    /// kept one costs one wake at its old end time.
    pub fn run_try_on_timer(&self) -> Result<Vec<Settled>, Error> {
        let mut settled = Vec::new();
        loop {
            settled.extend(self.settle(now_ms())?);
            let Some(try_on) = self.store().try_on()? else { return Ok(settled) };
            let wait = try_on.expires_ms.saturating_sub(now_ms()).max(1);
            std::thread::sleep(Duration::from_millis(wait));
        }
    }

    /// The running try-on; a stale one (moved past) is dropped. The caller
    /// holds the lock.
    fn live_try_on_locked(&self) -> Result<Option<TryOn>, Error> {
        let Some(try_on) = self.store().try_on()? else { return Ok(None) };
        if Some(try_on.generation) == self.current_generation()? {
            return Ok(Some(try_on));
        }
        self.store().put_try_on(None)?;
        Ok(None)
    }

    /// With `due` set, reverts only once `due` reaches the end time; with
    /// `None`, reverts now. The caller holds the lock.
    fn settle_locked(
        &self,
        due: Option<u64>,
        origin: &str,
        now_ms: u64,
    ) -> Result<Option<Settled>, Error> {
        let Some(try_on) = self.store().try_on()? else { return Ok(None) };
        if Some(try_on.generation) != self.current_generation()? {
            self.store().put_try_on(None)?;
            return Ok(Some(Settled::Ended { try_on }));
        }
        if due.is_some_and(|due| due < try_on.expires_ms) {
            return Ok(None);
        }
        // The record goes whatever the restore answers: a revert that cannot
        // be made (a file cmux keeps no copy of is in the way) is said once
        // and leaves the setup applied, rather than failing every look.
        self.store().put_try_on(None)?;
        let Some(to) = try_on.revert_to else {
            return Ok(Some(Settled::Ended { try_on }));
        };
        let label = format!("changes made while trying on: {}", try_on.label);
        let restored = self.restore_locked(to, Kind::Autosaved, origin, &label, now_ms)?;
        // The library goes back with it: what nobody kept leaves it, and
        // what was off before is off again. A library that cannot be
        // written never fails the revert.
        if let Some(mark) = &try_on.library {
            let _ = self.library_follow_locked(&mark.on, Some(&mark.names), now_ms);
        }
        Ok(Some(Settled::Reverted { try_on, restored }))
    }
}

pub(crate) fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_millis() as u64)
}
