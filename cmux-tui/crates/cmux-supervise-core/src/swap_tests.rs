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
    assert!(matches!(make_before_break(&mut broken, Duration::from_secs(1)), Swapped::KeptOld(_)));
    assert_eq!(broken.log, ["start", "ready?", "abort"], "no handover: the old one serves");
}
