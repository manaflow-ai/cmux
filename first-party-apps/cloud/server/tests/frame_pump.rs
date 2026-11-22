//! The C13 pump of one connector link (`cmux.terminal.connector/1`
//! `dataPlane`): carrier bytes become `data` frames inside the out credit,
//! host `data` frames become carrier bytes inside the in credit, credit is
//! granted only for bytes the carrier took, and each channel ends once.

use cmux_cloud::connector::pump::{MAX_DATA_FRAME, Pump};
use cmux_terminal_iface::{
    DEFAULT_WINDOW_BYTES, Direction, End, FrameBody, Lost, MIN_WINDOW_BYTES,
};

const WINDOW: u32 = MIN_WINDOW_BYTES;

fn lost(frames: &[FrameBody]) -> Vec<Lost> {
    frames
        .iter()
        .filter_map(|f| match f {
            FrameBody::End(End::Lost(lost)) => Some(lost.clone()),
            _ => None,
        })
        .collect()
}

#[test]
fn a_window_outside_the_interface_bounds_is_refused() {
    assert!(Pump::new(1).is_err());
    assert!(Pump::new(WINDOW).is_ok());
    assert!(Pump::new(DEFAULT_WINDOW_BYTES).is_ok());
}

#[test]
fn carrier_bytes_become_data_frames_with_running_offsets() {
    let mut pump = Pump::new(WINDOW).unwrap();
    assert_eq!(pump.read_budget(), MAX_DATA_FRAME.min(WINDOW as usize));
    pump.from_carrier(b"hello".to_vec()).unwrap();
    pump.from_carrier(b" world".to_vec()).unwrap();
    assert_eq!(
        pump.take_frames(),
        vec![
            FrameBody::Data { offset: 5, bytes: b"hello".to_vec() },
            FrameBody::Data { offset: 11, bytes: b" world".to_vec() },
        ]
    );
    assert!(pump.take_frames().is_empty(), "frames are given once");
}

#[test]
fn the_carrier_is_not_read_when_the_out_credit_is_spent() {
    let mut pump = Pump::new(WINDOW).unwrap();
    let mut sent = 0usize;
    while pump.read_budget() > 0 {
        let n = pump.read_budget();
        pump.from_carrier(vec![7; n]).unwrap();
        sent += n;
    }
    assert_eq!(sent, WINDOW as usize, "exactly one window goes out without credit");
    // More than the budget is the caller's bug: refused, nothing taken.
    assert!(pump.from_carrier(vec![1]).is_err());
    assert_eq!(pump.take_frames().len(), sent.div_ceil(MAX_DATA_FRAME));
    // The host consumed 100 bytes: exactly 100 more may be read.
    pump.push(FrameBody::Credit { direction: Direction::Out, bytes: 100 }).unwrap();
    assert_eq!(pump.read_budget(), 100);
    assert!(pump.take_frames().is_empty());
}

#[test]
fn host_data_reaches_the_carrier_and_credit_follows_only_its_writes() {
    let mut pump = Pump::new(WINDOW).unwrap();
    pump.push(FrameBody::Data { offset: 3, bytes: b"abc".to_vec() }).unwrap();
    pump.push(FrameBody::Data { offset: 5, bytes: b"de".to_vec() }).unwrap();
    assert_eq!(pump.take_carrier_bytes(), b"abcde".to_vec());
    assert!(pump.take_carrier_bytes().is_empty(), "bytes go to the carrier once");
    assert!(pump.take_frames().is_empty(), "no credit before the carrier took the bytes");
    pump.carrier_wrote(3).unwrap();
    assert_eq!(pump.take_frames(), vec![FrameBody::Credit { direction: Direction::In, bytes: 3 }]);
    pump.carrier_wrote(2).unwrap();
    assert_eq!(pump.take_frames(), vec![FrameBody::Credit { direction: Direction::In, bytes: 2 }]);
    // More than was handed to the carrier is a caller bug.
    assert!(pump.carrier_wrote(1).is_err());
}

#[test]
fn host_data_past_the_in_credit_ends_the_channel_with_lost_credit() {
    let mut pump = Pump::new(WINDOW).unwrap();
    let full = vec![0u8; WINDOW as usize];
    pump.push(FrameBody::Data { offset: u64::from(WINDOW), bytes: full }).unwrap();
    // Not written to the carrier yet: no credit, so one more byte is a violation.
    pump.push(FrameBody::Data { offset: u64::from(WINDOW) + 1, bytes: vec![1] }).unwrap();
    let frames = pump.take_frames();
    assert_eq!(lost(&frames), vec![Lost::new("credit", false)]);
    assert!(pump.is_ended());
    assert!(pump.take_carrier_bytes().is_empty(), "nothing reaches the carrier after the end");
    assert_eq!(pump.read_budget(), 0);
}

#[test]
fn a_gap_or_an_overlap_ends_the_channel_with_lost() {
    for (offset, reason) in [(4, "gap"), (2, "overlap")] {
        let mut pump = Pump::new(WINDOW).unwrap();
        pump.push(FrameBody::Data { offset, bytes: b"abc".to_vec() }).unwrap();
        assert_eq!(lost(&pump.take_frames()), vec![Lost::new(reason, false)], "{reason}");
        assert!(pump.is_ended());
    }
}

#[test]
fn credit_past_one_window_or_for_the_wrong_direction_ends_the_channel() {
    let mut pump = Pump::new(WINDOW).unwrap();
    pump.push(FrameBody::Credit { direction: Direction::Out, bytes: 1 }).unwrap();
    assert_eq!(lost(&pump.take_frames()), vec![Lost::new("credit", false)]);

    let mut pump = Pump::new(WINDOW).unwrap();
    pump.push(FrameBody::Credit { direction: Direction::In, bytes: 1 }).unwrap();
    assert_eq!(lost(&pump.take_frames()), vec![Lost::new("credit direction", false)]);
}

#[test]
fn each_channel_ends_exactly_once_after_its_last_data() {
    let mut pump = Pump::new(WINDOW).unwrap();
    pump.from_carrier(b"last".to_vec()).unwrap();
    pump.carrier_closed(Lost::new("the carrier closed", true));
    pump.carrier_closed(Lost::new("again", true));
    pump.close(Lost::new("closed", true));
    let frames = pump.take_frames();
    assert_eq!(
        frames,
        vec![
            FrameBody::Data { offset: 4, bytes: b"last".to_vec() },
            FrameBody::End(End::Lost(Lost::new("the carrier closed", true))),
        ]
    );
    assert!(pump.push(FrameBody::Data { offset: 1, bytes: vec![1] }).is_err());
    assert!(pump.from_carrier(vec![1]).is_err());
    assert!(pump.take_frames().is_empty());
}

#[test]
fn the_hosts_end_ends_the_channel_without_an_end_back() {
    let mut pump = Pump::new(WINDOW).unwrap();
    pump.push(FrameBody::Data { offset: 2, bytes: b"hi".to_vec() }).unwrap();
    pump.push(FrameBody::End(End::Lost(Lost::new("closed", true)))).unwrap();
    assert!(pump.is_ended());
    assert!(pump.take_frames().is_empty(), "the host already ended the channel");
    assert!(pump.take_carrier_bytes().is_empty());
    // Bytes the carrier finishes writing after the end grant nothing.
    assert!(pump.carrier_wrote(0).is_ok());
    assert!(pump.take_frames().is_empty());
}

#[test]
fn buffered_host_bytes_never_pass_one_window() {
    let mut pump = Pump::new(WINDOW).unwrap();
    let mut offset = 0u64;
    let mut granted_back = 0u64;
    // The host sends as much as its credit allows; the carrier is slow and
    // takes bytes but writes only half of them before more come.
    for _ in 0..8 {
        let room = u64::from(WINDOW) - (offset - granted_back);
        if room == 0 {
            break;
        }
        offset += room;
        pump.push(FrameBody::Data { offset, bytes: vec![1; room as usize] }).unwrap();
        let taken = pump.take_carrier_bytes().len() as u64;
        assert!(taken <= u64::from(WINDOW));
        pump.carrier_wrote(taken / 2).unwrap();
        for frame in pump.take_frames() {
            match frame {
                FrameBody::Credit { direction: Direction::In, bytes } => {
                    granted_back += u64::from(bytes);
                }
                other => panic!("unexpected frame {other:?}"),
            }
        }
    }
    assert!(!pump.is_ended(), "a host inside its credit never ends the channel");
}
