use super::*;

#[test]
fn synthetic_surface_carries_the_marker_and_input_bumps_it() {
    super::super::sys::load().expect("frameworks");
    let mut surface = PixelBuffer::new(1280, 720).expect("IOSurface-backed 420v buffer");
    assert!(surface.io_surface().is_some());
    let painter = Painter::new(crate::synthetic::Scene::Bars, 1280, 720);
    surface.paint(&painter, (1280, 720), 41, 0).expect("paint");
    assert_eq!(surface.marker(), Some(41));

    // The desktop half: a key press bumps the counter and makes a frame due; a release,
    // a move and text do not bump.
    let (wake_read, wake) = UnixStream::pair().expect("pair");
    wake_read.set_nonblocking(true).expect("nonblocking");
    wake.set_nonblocking(true).expect("nonblocking");
    let shared =
        Arc::new(Shared { counter: AtomicU32::new(0), wake, stop: AtomicBool::new(false) });
    let mut desktop = SyntheticDesktop {
        shared: shared.clone(),
        wake_read,
        size: (1280, 720),
        motion: Motion::Still,
        ticker: None,
        reported_whole: true,
    };
    let mut damage = Vec::new();
    desktop.drain(&mut damage).expect("drain");
    assert!(damage.is_empty(), "nothing due before input");
    desktop.inject(&InputEvent::Key { usage: 4, down: true }).expect("inject");
    desktop.inject(&InputEvent::Key { usage: 4, down: false }).expect("inject");
    desktop.inject(&InputEvent::Pointer { x: 1, y: 1 }).expect("inject");
    assert_eq!(shared.counter.load(Ordering::Relaxed), 1);
    desktop.drain(&mut damage).expect("drain");
    assert_eq!(damage.len(), 1, "the press made one frame due");
    assert_eq!(damage[0].height, crate::marker::CELL);
    let counter = shared.counter.load(Ordering::Relaxed);
    surface.paint(&painter, (1280, 720), counter, 0).expect("paint");
    assert_eq!(surface.marker(), Some(1));
}
