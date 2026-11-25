//! Make-before-break replacement (H6, design 4.2): the new one starts beside the old one,
//! passes readiness, then takes over by handover. If it fails readiness, it is stopped and the
//! old one keeps serving. The steps are the caller's; the order and the rule are here, so every
//! supervisor swaps the same way.

use std::time::{Duration, Instant};

/// How a swap ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Swapped {
    /// The new one took over.
    New,
    /// The new one never got ready (or could not start, or the handover failed): the old one
    /// still serves.
    KeptOld(String),
}

/// The steps of one swap.
pub trait Swap {
    /// The started new one (a child, a pid).
    type New;
    /// Start the new one beside the old one. It must not take anything from the old one yet.
    fn start_new(&mut self) -> Result<Self::New, String>;
    /// Whether the new one answers a real request. Asked until `deadline`, on change.
    fn ready(&mut self, new: &mut Self::New, deadline: Instant) -> Result<(), String>;
    /// The new one takes the endpoint and the old one drains.
    fn hand_over(&mut self, new: &mut Self::New) -> Result<(), String>;
    /// The new one failed: stop it, leave the old one alone.
    fn abort(&mut self, new: Self::New);
}

/// Swap within `ready_within` for the readiness step.
pub fn make_before_break<S: Swap>(steps: &mut S, ready_within: Duration) -> Swapped {
    let mut new = match steps.start_new() {
        Ok(new) => new,
        Err(why) => return Swapped::KeptOld(format!("the new one did not start: {why}")),
    };
    if let Err(why) = steps.ready(&mut new, Instant::now() + ready_within) {
        steps.abort(new);
        return Swapped::KeptOld(format!("the new one never got ready: {why}"));
    }
    match steps.hand_over(&mut new) {
        Ok(()) => Swapped::New,
        Err(why) => {
            steps.abort(new);
            Swapped::KeptOld(format!("the handover failed: {why}"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Fake {
        ready: bool,
        log: Vec<&'static str>,
    }

    impl Swap for Fake {
        type New = ();
        fn start_new(&mut self) -> Result<(), String> {
            self.log.push("start");
            Ok(())
        }
        fn ready(&mut self, _: &mut (), _: Instant) -> Result<(), String> {
            self.log.push("ready?");
            if self.ready { Ok(()) } else { Err("no answer".into()) }
        }
        fn hand_over(&mut self, _: &mut ()) -> Result<(), String> {
            self.log.push("hand over");
            Ok(())
        }
        fn abort(&mut self, _: ()) {
            self.log.push("abort");
        }
    }

    #[test]
    fn the_old_one_is_touched_only_after_the_new_one_is_ready() {
        let mut ok = Fake { ready: true, ..Fake::default() };
        assert_eq!(make_before_break(&mut ok, Duration::from_secs(1)), Swapped::New);
        assert_eq!(ok.log, ["start", "ready?", "hand over"]);
        let mut broken = Fake::default();
        assert!(matches!(
            make_before_break(&mut broken, Duration::from_secs(1)),
            Swapped::KeptOld(_)
        ));
        assert_eq!(broken.log, ["start", "ready?", "abort"], "no handover: the old one serves");
    }
}
