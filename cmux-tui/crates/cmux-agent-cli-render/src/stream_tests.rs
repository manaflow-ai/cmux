use super::*;
use crate::{Line, Style};

fn screen(lines: &[&str]) -> Grid {
    let mut grid = Grid::blank(20, 4);
    for (slot, text) in grid.cells.iter_mut().zip(lines) {
        let mut line = Line::new();
        line.push(text, Style::fg(174));
        *slot = line.into_row(20);
    }
    grid
}

/// What a viewer shows after applying `frames` in order.
fn viewer(frames: &[&Frame]) -> Grid {
    let blank = Grid::blank(20, 4);
    let mut shown = Overlay::new(20, 4);
    for frame in frames {
        if frame.base.is_none() {
            shown = Overlay::new(20, 4);
        }
        shown.apply_delta(&Delta::decode(&frame.data).unwrap(), &blank);
    }
    shown.compose(&blank)
}

#[test]
fn frames_turn_the_viewer_into_the_real_screen() {
    let mut stream = HybridStream::new(20, 4);
    let a = stream.update(&screen(&["> hi"]), 0).unwrap();
    assert_eq!((a.base, a.frame), (Some(0), 1));
    assert!(stream.update(&screen(&["> hi"]), 5).is_none(), "nothing changed");
    let b = stream.update(&screen(&["> hi", "✻ Misting…"]), 10).unwrap();
    assert_eq!((b.base, b.frame), (Some(1), 2));
    assert_eq!(viewer(&[&a, &b]).parity(&screen(&["> hi", "✻ Misting…"])), (80, 80));
    let key = stream.keyframe(20);
    assert_eq!((key.base, key.frame), (None, 2));
    assert_eq!(viewer(&[&key]).parity(&screen(&["> hi", "✻ Misting…"])), (80, 80));
}

#[test]
fn a_resume_sends_only_what_changed_since_the_viewers_frame() {
    let mut stream = HybridStream::new(20, 4);
    let a = stream.update(&screen(&["one", "two", "three"]), 0).unwrap();
    // The viewer drops after frame 1; two frames go out without it.
    stream.update(&screen(&["one", "two", "three", "four"]), 10).unwrap();
    stream.update(&screen(&["one", "two!", "three", "four"]), 20).unwrap();
    let resumed = stream.resume(1, 30).unwrap();
    assert_eq!((resumed.base, resumed.frame), (Some(1), 3));
    assert!(resumed.data.len() < stream.keyframe(30).data.len());
    let want = screen(&["one", "two!", "three", "four"]);
    assert_eq!(viewer(&[&a, &resumed]).parity(&want), (80, 80));
    // Up to date: an empty delta.
    let again = stream.resume(3, 40).unwrap();
    assert_eq!(viewer(&[&a, &resumed, &again]).parity(&stream.shown()), (80, 80));
    // A frame the stream never sent.
    assert!(stream.resume(9, 40).is_none());
}

#[test]
fn a_resume_from_a_frame_past_the_kept_ones_needs_a_keyframe() {
    let mut stream = HybridStream::new(20, 4);
    for n in 0..(RESUME_FRAMES as u64 + 10) {
        stream.update(&screen(&[&format!("line {n}")]), n);
    }
    assert!(stream.resume(1, 0).is_none());
    let kept = stream.frame() - 5;
    assert!(stream.resume(kept, 0).is_some());
}

#[test]
fn a_resize_starts_over() {
    let mut stream = HybridStream::new(20, 4);
    stream.update(&screen(&["one"]), 0).unwrap();
    stream.resize(30, 6);
    assert_eq!(stream.size(), (30, 6));
    assert_eq!(stream.frame(), 2);
    assert!(stream.resume(1, 0).is_none());
    assert!(stream.resume(2, 0).is_some());
}

#[test]
fn the_pacer_holds_a_burst_and_keeps_an_interval() {
    let start = Instant::now();
    let ms = |n| start + Duration::from_millis(n);
    let mut pacer = FramePacer::default();
    assert_eq!(pacer.due(), None);
    pacer.wrote(ms(0));
    pacer.wrote(ms(3));
    assert_eq!(pacer.due(), Some(ms(8)));
    pacer.sent(ms(8));
    assert_eq!(pacer.due(), None);
    pacer.wrote(ms(20));
    assert_eq!(pacer.due(), Some(ms(108)));
    pacer.sent(ms(108));
    // Idle for longer than an interval: only the settle.
    pacer.wrote(ms(500));
    assert_eq!(pacer.due(), Some(ms(508)));
}
