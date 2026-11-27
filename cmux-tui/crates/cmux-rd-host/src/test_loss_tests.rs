use super::{Carrier, Control, DatagramDeparture, Incoming, LossyCarrier, RawFd, TestLoss};
use cmux_rd_proto::{DatagramHeader, DatagramKind};
use std::io;

fn datagram(kind: DatagramKind) -> Vec<u8> {
    let mut d = DatagramHeader {
        flags: 0,
        kind,
        stream: 0,
        frame: 1,
        index: 0,
        count: 1,
        fec_count: 0,
        transport_seq: 0,
    }
    .encode()
    .to_vec();
    d.extend_from_slice(&[0; 32]);
    d
}

/// The carrier it wraps: what reached it, frame by frame.
#[derive(Default)]
struct Sink {
    frames: Vec<Vec<Vec<u8>>>,
}

impl Carrier for Sink {
    fn drain_departures(&mut self, _out: &mut Vec<DatagramDeparture>) {}
    fn departure_overflows(&self) -> u64 {
        7
    }
    fn fds(&self) -> Vec<RawFd> {
        Vec::new()
    }
    fn receive(&mut self, _out: &mut Vec<Incoming>) -> Result<(), String> {
        Ok(())
    }
    fn send_datagram(&mut self, datagram: &[u8]) -> io::Result<()> {
        self.frames.push(vec![datagram.to_vec()]);
        Ok(())
    }
    fn send_datagram_frame(&mut self, datagrams: Vec<Vec<u8>>, _droppable: bool) -> io::Result<()> {
        self.frames.push(datagrams);
        Ok(())
    }
    fn send_control(&mut self, _control: &Control) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn a_frame_loses_its_media_and_keeps_the_rest_as_one_frame() {
    let (video, feedback) = (datagram(DatagramKind::Video), datagram(DatagramKind::Feedback));
    let mut sink = Sink::default();
    let mut lossy = LossyCarrier { inner: &mut sink, loss: TestLoss::new(100.0, 1).expect("on") };
    lossy.send_datagram_frame(vec![video.clone(), feedback.clone(), video.clone()], true).unwrap();
    lossy.send_datagram_frame(vec![video.clone()], true).unwrap();
    assert_eq!(lossy.departure_overflows(), 7, "the wrapped carrier's count");
    drop(lossy);
    assert_eq!(
        sink.frames,
        vec![vec![feedback]],
        "media gone, feedback kept, an all-media frame sends nothing"
    );
}

#[test]
fn off_unless_above_zero() {
    assert!(TestLoss::new(0.0, 1).is_none());
    assert!(TestLoss::new(-1.0, 1).is_none());
    assert!(TestLoss::new(f64::NAN, 1).is_none());
}

#[test]
fn drops_about_the_rate_of_media_from_a_seed_and_never_feedback() {
    let video = datagram(DatagramKind::Video);
    let feedback = datagram(DatagramKind::Feedback);
    let mut a = TestLoss::new(3.0, 7).expect("on");
    let mut b = TestLoss::new(3.0, 7).expect("on");
    let drops_a: Vec<bool> = (0..20_000).map(|_| a.drops(&video)).collect();
    let drops_b: Vec<bool> = (0..20_000).map(|_| b.drops(&video)).collect();
    assert_eq!(drops_a, drops_b, "one seed, one sequence");
    let rate = a.dropped as f64 / 20_000.0;
    assert!((0.025..0.035).contains(&rate), "about 3 %: {rate}");
    assert!((0..1_000).all(|_| !a.drops(&feedback)));
    let mut all = TestLoss::new(100.0, 1).expect("on");
    assert!((0..1_000).all(|_| all.drops(&video)));
}
