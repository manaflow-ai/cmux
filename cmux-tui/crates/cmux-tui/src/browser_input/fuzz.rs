//! Fuzz driver for the browser input scheduler (`crate::fuzzing`).
//!
//! The driver is the worker pool: the scheduler has no threads, and the
//! driver pops its ready queue and runs the workers' own `run_lane`, so
//! producers and worker turns interleave in input order. Surfaces are
//! `RemoteBrowserUnsupported` handles, whose browser calls fail without I/O.
//! The checked contract: global admission always equals the events the lanes
//! hold, stays inside its bounds, and returns to zero when the lanes drain; a
//! lane nobody can reach again holds no events.

use super::*;
use crate::fuzzing::FuzzBytes;
use std::sync::PoisonError;

const NARROW_SURFACES: u8 = 8;
/// Past the live-lane limit, so idle-lane eviction and refusal are reachable.
const WIDE_SURFACES: u16 = MAX_BROWSER_INPUT_SURFACES as u16 + 16;
const DRAIN_TURNS: usize = 1 << 20;

const MOUSE_TYPES: [&str; 3] = ["mousePressed", "mouseReleased", "mouseMoved"];
const BUTTONS: [Option<&str>; 3] = [Some("left"), Some("right"), None];
const KEY_TYPES: [&str; 4] = ["keyDown", "keyUp", "rawKeyDown", "char"];
const NAMED_KEYS: [&str; 4] = ["Enter", "Backspace", "ArrowLeft", "Tab"];

struct Driver {
    scheduler: Arc<BrowserInputScheduler>,
    dispatcher: BrowserInputDispatcher,
    /// Every lane the dispatcher created that is still reachable, by address.
    lanes: HashMap<usize, Arc<ScheduledSurfaceInputLane>>,
}

pub(crate) fn one_input(data: &[u8]) {
    let mut input = FuzzBytes::new(data);
    let mut driver = Driver::new();
    while let Some(op) = input.byte() {
        if driver.step(op, &mut input).is_none() {
            break;
        }
        driver.check();
    }
    driver.drain();
}

/// A browser event from a selector and six parameter bytes; a burst rebuilds
/// the same event from the same bytes.
fn event_kind(selector: u8, p: [u8; 6]) -> BrowserInputKind {
    let x = f64::from(p[1]);
    let y = f64::from(p[2]);
    let frame_seq = u64::from(p[5]);
    let key = if p[0] & 1 == 0 {
        BrowserKey::Character(char::from(p[1]))
    } else {
        BrowserKey::Named(NAMED_KEYS[usize::from(p[1]) % NAMED_KEYS.len()])
    };
    let modifiers = u32::from(p[3] & 0x0f);
    let text = (p[4] & 1 == 1).then_some("a");
    match selector % 13 {
        0..=2 => BrowserInputKind::Mouse {
            event_type: MOUSE_TYPES[usize::from(p[0]) % MOUSE_TYPES.len()],
            x,
            y,
            button: BUTTONS[usize::from(p[3]) % BUTTONS.len()],
            click_count: (p[4] & 1 == 1).then_some(u32::from(p[4] >> 1)),
            frame_seq,
        },
        3 => BrowserInputKind::Wheel { x, y, delta_y: f64::from(p[3] as i8), frame_seq },
        4 => BrowserInputKind::Key {
            event_type: KEY_TYPES[usize::from(p[0] >> 1) % KEY_TYPES.len()],
            key,
            code: "KeyA",
            windows_virtual_key_code: u32::from(p[2]),
            modifiers,
            text,
        },
        5 => BrowserInputKind::KeyPress {
            key,
            code: "KeyA",
            windows_virtual_key_code: u32::from(p[2]),
            modifiers,
            text,
        },
        // Up to 16 KiB each, so bursts reach the global byte bound.
        6 => BrowserInputKind::InsertText("x".repeat(usize::from(p[0]) * 64)),
        7 => BrowserInputKind::Resize {
            cols: u16::from(p[0] % 4),
            rows: u16::from(p[1] % 4),
            reassert: p[2] & 1 == 1,
            _claim: (p[3] & 1 == 1).then(|| Box::new(p[4]) as Box<dyn Send>),
            on_result: (p[3] & 2 == 2)
                .then(|| Box::new(|_: Option<u64>| {}) as Box<dyn FnOnce(Option<u64>) + Send>),
        },
        8 => BrowserInputKind::Navigate(format!("https://example.test/{}", p[0])),
        9 => BrowserInputKind::Back,
        10 => BrowserInputKind::Forward,
        11 => BrowserInputKind::Reload,
        _ => match p[0] & 1 {
            0 => BrowserInputKind::Activate,
            _ => BrowserInputKind::Presented { frame_seq },
        },
    }
}

impl Driver {
    fn new() -> Self {
        let failed_resizes = Arc::new(Mutex::new(HashMap::new()));
        let scheduler = Arc::new(BrowserInputScheduler {
            ready: Mutex::new(ReadySurfaceLanes::default()),
            available: Condvar::new(),
            admission: Mutex::new(BrowserInputAdmission::default()),
            failed_resizes: failed_resizes.clone(),
            on_resize_failure: Arc::new(|failure: BrowserResizeFailure| {
                assert!(!failure.error.is_empty(), "a resize failure carries its reason");
            }),
            on_control_failure: Arc::new(|error: String| {
                assert!(!error.is_empty(), "a control failure carries its reason");
            }),
        });
        let dispatcher = BrowserInputDispatcher::with_scheduler(scheduler.clone(), failed_resizes);
        Self { scheduler, dispatcher, lanes: HashMap::new() }
    }

    fn step(&mut self, op: u8, input: &mut FuzzBytes<'_>) -> Option<()> {
        match op % 8 {
            0 | 1 => {
                let surface_id = narrow_surface(input)?;
                let (selector, params) = event_bytes(input)?;
                self.enqueue(surface_id, selector, params);
            }
            2 => {
                let surface_id = narrow_surface(input)?;
                let (selector, params) = event_bytes(input)?;
                let copies = usize::from(input.byte()?) * 8 + 1;
                for _ in 0..copies {
                    self.enqueue(surface_id, selector, params);
                }
            }
            3 => {
                // One event to each of many surfaces: the live-lane bound.
                let base = input.u16()? % WIDE_SURFACES;
                let count = u16::from(input.byte()?) + 1;
                let (selector, params) = event_bytes(input)?;
                for offset in 0..count {
                    let surface_id = SurfaceId::from((base + offset) % WIDE_SURFACES);
                    self.enqueue(surface_id, selector, params);
                }
            }
            4 => {
                for _ in 0..=input.byte()? % 8 {
                    self.run_one_turn();
                }
            }
            5 => {
                let surface_id = match input.flag()? {
                    true => SurfaceId::from(input.u16()? % WIDE_SURFACES),
                    false => narrow_surface(input)?,
                };
                self.dispatcher.forget_surface(surface_id);
            }
            6 => self.dispatcher.clear_resize_failures(),
            _ => {
                let mask = input.byte()?;
                let visible = (0..NARROW_SURFACES)
                    .filter(|bit| mask & (1 << bit) != 0)
                    .map(SurfaceId::from)
                    .collect::<HashSet<_>>();
                let _ = self.dispatcher.visible_resize_retry_due(&visible);
                let _ = self.dispatcher.resize_retry_due();
            }
        }
        Some(())
    }

    fn enqueue(&mut self, surface_id: SurfaceId, selector: u8, params: [u8; 6]) {
        let kind = event_kind(selector, params);
        let surface = SurfaceHandle::RemoteBrowserUnsupported;
        let _ = self.dispatcher.enqueue(BrowserInputEvent { surface_id, surface, kind });
        if let Some(lane) =
            self.dispatcher.lanes.lock().unwrap_or_else(PoisonError::into_inner).get(&surface_id)
        {
            self.lanes.entry(Arc::as_ptr(lane) as usize).or_insert_with(|| lane.clone());
        }
    }

    /// One worker turn on the front ready lane; false when none is ready.
    fn run_one_turn(&self) -> bool {
        let lane =
            self.scheduler.ready.lock().unwrap_or_else(PoisonError::into_inner).lanes.pop_front();
        let Some(lane) = lane else {
            return false;
        };
        self.scheduler.run_lane(lane);
        true
    }

    fn check(&mut self) {
        // A lane only this driver holds is out of the map and the ready
        // queue: nothing can deliver its events any more.
        self.lanes.retain(|_, lane| {
            let reachable = Arc::strong_count(lane) > 1;
            if !reachable {
                assert!(!lane.has_pending(), "an unreachable browser lane kept queued events");
            }
            reachable
        });
        let queued = self
            .lanes
            .values()
            .map(|lane| lane.lane.queued_count.load(Ordering::Acquire))
            .sum::<usize>();
        let admission = self.scheduler.admission.lock().unwrap_or_else(PoisonError::into_inner);
        assert_eq!(admission.queued_events, queued, "global admission drifted from lane counts");
        assert!(
            admission.queued_events <= GLOBAL_QUEUE_CAPACITY + GLOBAL_RELEASE_RESERVE_CAPACITY,
            "browser input admission passed its event bound: {}",
            admission.queued_events
        );
        assert!(
            admission.retained_bytes <= GLOBAL_QUEUE_MAX_BYTES + GLOBAL_RELEASE_RESERVE_MAX_BYTES,
            "browser input admission passed its byte bound: {}",
            admission.retained_bytes
        );
        drop(admission);
        assert!(
            self.dispatcher.lanes.lock().unwrap_or_else(PoisonError::into_inner).len()
                <= MAX_BROWSER_INPUT_SURFACES
        );
    }

    fn drain(&mut self) {
        let mut turns = 0;
        while self.run_one_turn() {
            turns += 1;
            assert!(turns < DRAIN_TURNS, "browser input lanes did not drain");
        }
        self.check();
        let admission = self.scheduler.admission.lock().unwrap_or_else(PoisonError::into_inner);
        assert_eq!(admission.queued_events, 0, "drained lanes left admitted events");
        assert_eq!(admission.retained_bytes, 0, "drained lanes left admitted bytes");
    }
}

fn narrow_surface(input: &mut FuzzBytes<'_>) -> Option<SurfaceId> {
    Some(SurfaceId::from(input.byte()? % NARROW_SURFACES))
}

fn event_bytes(input: &mut FuzzBytes<'_>) -> Option<(u8, [u8; 6])> {
    let selector = input.byte()?;
    let bytes = input.take(6);
    let params = <[u8; 6]>::try_from(bytes).ok()?;
    Some((selector, params))
}
