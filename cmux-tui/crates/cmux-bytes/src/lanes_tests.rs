use super::*;

#[test]
fn faults_jump_the_fill_but_the_fill_still_moves() {
    let mut s = Scheduler::new(8);
    for i in 0..100 {
        s.push(Lane::Fill, i);
    }
    for i in 1000..1020 {
        s.push(Lane::Fault, i);
    }
    let first: Vec<_> = (0..9).map(|_| s.pop().unwrap()).collect();
    assert!(first[..7].iter().all(|(l, _)| *l == Lane::Fault));
    assert!(first.iter().any(|(l, _)| *l == Lane::Fill));
    assert!(s.promote(Lane::Fill, |i| *i == 50));
    assert_eq!(s.pop().unwrap(), (Lane::Fault, 1008));
}

#[test]
fn drain_sends_in_lane_order() {
    struct Rec(Vec<(Lane, u32)>);
    impl LaneSink<u32> for Rec {
        fn send(&mut self, lane: Lane, item: u32) -> io::Result<()> {
            self.0.push((lane, item));
            Ok(())
        }
    }
    let mut s = Scheduler::new(100);
    s.push(Lane::Fill, 3);
    s.push(Lane::Hot, 2);
    s.push(Lane::Manifest, 0);
    let mut rec = Rec(Vec::new());
    assert_eq!(drain(&mut s, &mut rec).ok(), Some(3));
    assert_eq!(rec.0, vec![(Lane::Manifest, 0), (Lane::Hot, 2), (Lane::Fill, 3)]);
}
