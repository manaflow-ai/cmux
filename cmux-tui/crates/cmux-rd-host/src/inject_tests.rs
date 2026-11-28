use super::*;

impl Injector {
    fn master(&self) -> Option<PersonMaster> {
        match self.person {
            Person::Attached(m) => Some(m),
            _ => None,
        }
    }
}

#[test]
fn add_master_len_pads_the_name_to_four_bytes() {
    assert_eq!(add_master_len(""), 2);
    assert_eq!(add_master_len("abcd"), 3);
    assert_eq!(add_master_len(PERSON_MASTER), 2 + 3); // 11 bytes -> 12
}

#[test]
fn pick_master_needs_the_named_pointer_and_its_paired_keyboard() {
    let rows = vec![
        (2, DeviceType::MASTER_POINTER, 3, b"Virtual core pointer".to_vec()),
        (3, DeviceType::MASTER_KEYBOARD, 2, b"Virtual core keyboard".to_vec()),
        (11, DeviceType::MASTER_POINTER, 12, b"cmux person pointer".to_vec()),
        (12, DeviceType::MASTER_KEYBOARD, 11, b"cmux person keyboard".to_vec()),
    ];
    assert_eq!(
        pick_master(&rows, PERSON_MASTER),
        Some(PersonMaster { pointer: 11, keyboard: 12, core: 2, core_keyboard: 3 })
    );
    assert_eq!(pick_master(&rows, "agent"), None);
    assert_eq!(pick_master(&rows[..3], PERSON_MASTER), None);
}

#[test]
fn person_property_is_versioned_json() {
    let v: serde_json::Value = serde_json::from_str(&person_property(
        PersonMaster { pointer: 11, keyboard: 12, core: 2, core_keyboard: 3 },
        0x40_0001,
        true,
        1_700_000_000_000,
    ))
    .unwrap();
    assert_eq!(v["button_held"], true);
    assert_eq!(v["v"], 1);
    assert_eq!(v["window"], 0x40_0001);
    assert_eq!(v["pointer"], 11);
    assert_eq!(v["last_input_unix_ms"], 1_700_000_000_000u64);
    assert_eq!(v["pid"], std::process::id());
}

fn press() -> InputEvent {
    InputEvent::Button { button: 1, down: true }
}
fn release() -> InputEvent {
    InputEvent::Button { button: 1, down: false }
}
fn motion(x: i32) -> InputEvent {
    InputEvent::Pointer { x, y: 10 }
}

#[test]
fn hold_guard_passes_everything_while_the_agent_holds_nothing() {
    let mut g = HoldGuard::default();
    let t = Instant::now();
    assert_eq!(g.push(motion(1), t, || false), vec![motion(1)]);
    assert_eq!(g.push(press(), t, || false), vec![press()]);
    assert_eq!(g.push(release(), t, || false), vec![release()]);
    assert!(!g.waiting());
}

#[test]
fn hold_guard_never_asks_x_for_motion() {
    let mut g = HoldGuard::default();
    let t = Instant::now();
    let out = g.push(motion(1), t, || panic!("motion needs no query"));
    assert_eq!(out, vec![motion(1)]);
}

#[test]
fn hold_guard_waits_a_press_and_what_follows_until_the_agent_lets_go() {
    let mut g = HoldGuard::default();
    let t = Instant::now();
    assert_eq!(g.push(motion(1), t, || true), vec![motion(1)], "motion is not held");
    assert!(g.push(press(), t, || true).is_empty());
    let t1 = t + Duration::from_millis(100);
    assert!(g.push(motion(2), t1, || true).is_empty(), "queued behind the press");
    assert!(g.push(release(), t1, || true).is_empty());
    assert!(g.release(t + Duration::from_millis(500), || true).is_empty());
    assert!(g.waiting());
    // The agent released: the press and everything after it go, in order.
    let out = g.release(t + Duration::from_millis(600), || false);
    assert_eq!(out, vec![press(), motion(2), release()]);
    assert!(!g.waiting());
}

#[test]
fn hold_guard_sends_a_press_anyway_after_the_limit() {
    let mut g = HoldGuard::default();
    let t = Instant::now();
    assert!(g.push(press(), t, || true).is_empty());
    assert!(g.release(t + HOLD_LIMIT - Duration::from_millis(1), || true).is_empty());
    assert_eq!(g.release(t + HOLD_LIMIT, || true), vec![press()]);
    // The next press waits again, with its own limit.
    let t2 = t + HOLD_LIMIT + Duration::from_millis(10);
    assert_eq!(g.push(release(), t2, || true), vec![release()]);
    assert!(g.push(press(), t2, || true).is_empty());
    assert!(g.release(t2 + Duration::from_secs(1), || true).is_empty());
}

#[test]
fn hold_guard_counts_each_press_from_when_it_arrived() {
    let mut g = HoldGuard::default();
    let t = Instant::now();
    assert!(g.push(press(), t, || true).is_empty());
    assert!(g.push(release(), t, || true).is_empty());
    let t1 = t + Duration::from_millis(1500);
    assert!(g.push(press(), t1, || true).is_empty(), "a second press in the burst");
    assert!(g.push(release(), t1, || true).is_empty());
    // The first press's limit ends: it goes, and the second waits out its own.
    assert_eq!(g.release(t + HOLD_LIMIT, || true), vec![press(), release()]);
    assert!(g.release(t1 + HOLD_LIMIT - Duration::from_millis(1), || true).is_empty());
    assert_eq!(g.release(t1 + HOLD_LIMIT, || true), vec![press(), release()]);
    // A burst queued long ago goes at once: no press restarts its wait at the front.
    let mut g = HoldGuard::default();
    for _ in 0..5 {
        assert!(g.push(press(), t, || true).is_empty());
        assert!(g.push(release(), t, || true).is_empty());
    }
    assert_eq!(g.release(t + HOLD_LIMIT, || true).len(), 10);
}

#[test]
fn hold_guard_holds_scrolls_like_presses_and_clears_on_release_all() {
    let mut g = HoldGuard::default();
    let t = Instant::now();
    let scroll = InputEvent::Scroll { dx: 0, dy: 300, precise: false };
    assert!(presses(&scroll));
    assert!(!presses(&InputEvent::Scroll { dx: 0, dy: 50, precise: false }), "no wheel click");
    assert!(g.push(scroll, t, || true).is_empty());
    g.clear();
    assert!(!g.waiting());
    assert_eq!(g.push(press(), t, || false), vec![press()]);
}

#[test]
fn hold_guard_sends_everything_when_the_queue_overflows() {
    let mut g = HoldGuard::default();
    let t = Instant::now();
    assert!(g.push(press(), t, || true).is_empty());
    for i in 0..HOLD_QUEUE_MAX - 1 {
        assert!(g.push(motion(i as i32), t, || true).is_empty());
    }
    assert_eq!(g.push(release(), t, || true).len(), HOLD_QUEUE_MAX + 1);
    assert!(!g.waiting());
}

/// On a real Xvfb: an app focuses its window the usual way (core SetInputFocus), and
/// the person's keys reach it through the person master. Before the person keyboard
/// followed the core focus they reached no window (CMUX-572). The window sits away from
/// the person's pointer, so only the focus can route the key there.
#[test]
#[ignore = "needs Xvfb; run with --ignored on a Linux host"]
fn person_master_keys_reach_the_window_the_core_focus_names() {
    use x11rb::protocol::xproto::{CreateWindowAux, EventMask, InputFocus, WindowClass};
    use x11rb::protocol::Event;
    let xvfb = Xvfb::start();
    let display = xvfb.display.clone();
    let (app, screen) = x11rb::connect(Some(&display)).unwrap();
    let root = app.setup().roots[screen].root;
    let win = app.generate_id().unwrap();
    app.create_window(
        0,
        win,
        root,
        10,
        10,
        100,
        100,
        0,
        WindowClass::INPUT_OUTPUT,
        0,
        &CreateWindowAux::new().event_mask(EventMask::KEY_PRESS),
    )
    .unwrap();
    app.map_window(win).unwrap();
    app.set_input_focus(InputFocus::PARENT, win, x11rb::CURRENT_TIME).unwrap();
    app.sync().unwrap();

    let mut person = Injector::new(&display).unwrap();
    person.apply(&InputEvent::Pointer { x: 700, y: 500 }).unwrap();
    person.apply(&InputEvent::Key { usage: 0x0007_0004, down: true }).unwrap();
    person.apply(&InputEvent::Key { usage: 0x0007_0004, down: false }).unwrap();
    person.conn.sync().unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut pressed = false;
    while !pressed && Instant::now() < deadline {
        while let Some(event) = app.poll_for_event().unwrap() {
            pressed |= matches!(event, Event::KeyPress(k) if k.event == win);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    person.release_all().unwrap();
    assert!(pressed, "the person's key press reached the focused window");
}

/// On a real Xvfb with openbox, the desktop a Linux host shares: openbox focuses the
/// newest window, then the person clicks the other one and types. openbox focuses on
/// that click while it holds the person pointer's grab, so the server gives the person
/// keyboard the focus and the core keyboard keeps the old window. The key must reach
/// the window the person clicked (CMUX-572: the viewer's clicks moved windows, but no
/// typed key ever arrived).
#[test]
#[ignore = "needs Xvfb and openbox; run with --ignored on a Linux host"]
fn person_keys_reach_the_window_the_person_clicked_under_openbox() {
    use x11rb::protocol::xproto::{CreateWindowAux, EventMask, WindowClass};
    use x11rb::protocol::Event;
    let xvfb = Xvfb::start();
    let display = xvfb.display.clone();
    let _wm = Openbox::start(&display);
    let (app, screen) = x11rb::connect(Some(&display)).unwrap();
    let root = app.setup().roots[screen].root;
    let make = |x: i16| {
        let win = app.generate_id().unwrap();
        app.create_window(
            0,
            win,
            root,
            x,
            100,
            300,
            200,
            0,
            WindowClass::INPUT_OUTPUT,
            0,
            &CreateWindowAux::new().event_mask(EventMask::KEY_PRESS),
        )
        .unwrap();
        app.map_window(win).unwrap();
        app.sync().unwrap();
        win
    };
    let clicked = make(100);
    std::thread::sleep(Duration::from_millis(300));
    let newest = make(600);
    std::thread::sleep(Duration::from_millis(500));
    let at = app.translate_coordinates(clicked, root, 150, 100).unwrap().reply().unwrap();
    let (x, y) = (i32::from(at.dst_x), i32::from(at.dst_y));

    let mut person = Injector::new(&display).unwrap();
    person.apply(&InputEvent::Pointer { x, y }).unwrap();
    person.apply(&InputEvent::Button { button: 1, down: true }).unwrap();
    person.apply(&InputEvent::Button { button: 1, down: false }).unwrap();
    person.conn.sync().unwrap();
    std::thread::sleep(Duration::from_millis(300));
    person.apply(&InputEvent::Key { usage: 0x0007_0004, down: true }).unwrap();
    person.apply(&InputEvent::Key { usage: 0x0007_0004, down: false }).unwrap();
    person.conn.sync().unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    let (mut on_clicked, mut on_newest) = (false, false);
    while !on_clicked && Instant::now() < deadline {
        while let Some(event) = app.poll_for_event().unwrap() {
            if let Event::KeyPress(k) = event {
                on_clicked |= k.event == clicked;
                on_newest |= k.event == newest;
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    person.release_all().unwrap();
    assert!(
        on_clicked,
        "the key reached the clicked window (it went to the other one: {on_newest})"
    );
}

/// The person types in window A, a new window B then takes the core focus, and the person
/// clicks A and types again. The core change came before the click, so the click wins and
/// the second key reaches A, not B (review on #47957: copying the core focus at the next
/// key undid the click).
#[test]
#[ignore = "needs Xvfb and openbox; run with --ignored on a Linux host"]
fn a_click_after_a_new_window_took_the_core_focus_keeps_the_keys_on_the_clicked_window() {
    use x11rb::protocol::xproto::{CreateWindowAux, EventMask, WindowClass};
    use x11rb::protocol::Event;
    let xvfb = Xvfb::start();
    let display = xvfb.display.clone();
    let _wm = Openbox::start(&display);
    let (app, screen) = x11rb::connect(Some(&display)).unwrap();
    let root = app.setup().roots[screen].root;
    let make = |x: i16| {
        let win = app.generate_id().unwrap();
        app.create_window(
            0,
            win,
            root,
            x,
            100,
            300,
            200,
            0,
            WindowClass::INPUT_OUTPUT,
            0,
            &CreateWindowAux::new().event_mask(EventMask::KEY_PRESS),
        )
        .unwrap();
        app.map_window(win).unwrap();
        app.sync().unwrap();
        win
    };
    // Which windows the person's key presses reached, read for up to 2 s until `want`.
    let read = |want: Window| {
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut got = Vec::new();
        while !got.contains(&want) && Instant::now() < deadline {
            while let Some(event) = app.poll_for_event().unwrap() {
                if let Event::KeyPress(k) = event {
                    got.push(k.event);
                }
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        got
    };
    let type_a = |person: &mut Injector| {
        person.apply(&InputEvent::Key { usage: 0x0007_0004, down: true }).unwrap();
        person.apply(&InputEvent::Key { usage: 0x0007_0004, down: false }).unwrap();
        person.conn.sync().unwrap();
    };
    let click = |person: &mut Injector, win: Window| {
        let at = app.translate_coordinates(win, root, 150, 100).unwrap().reply().unwrap();
        person
            .apply(&InputEvent::Pointer { x: i32::from(at.dst_x), y: i32::from(at.dst_y) })
            .unwrap();
        person.apply(&InputEvent::Button { button: 1, down: true }).unwrap();
        person.apply(&InputEvent::Button { button: 1, down: false }).unwrap();
        person.conn.sync().unwrap();
        std::thread::sleep(Duration::from_millis(300));
    };
    let clicked = make(100);
    std::thread::sleep(Duration::from_millis(500));
    let mut person = Injector::new(&display).unwrap();
    click(&mut person, clicked);
    type_a(&mut person);
    let first = read(clicked);
    assert!(first.contains(&clicked), "the first key reached A, the only window: {first:?}");

    let newest = make(600);
    std::thread::sleep(Duration::from_millis(500));
    click(&mut person, clicked);
    type_a(&mut person);
    let second = read(clicked);
    person.release_all().unwrap();
    assert!(
        second.contains(&clicked) && !second.contains(&newest),
        "the key after the click reached A (clicked {clicked}, newest {newest}): {second:?}"
    );
}

/// On a real Xvfb: text the viewer sends as text (an emoji, an accented letter, a
/// character typed by a tool that posts each one with key code 0) reaches the focused
/// window as those characters, also while the person holds Shift. Before, the host
/// dropped every text event, so a viewer that typed through text sent nothing and one
/// that fell back to the key code typed "a" for each character (CMUX-572).
#[test]
#[ignore = "needs Xvfb; run with --ignored on a Linux host"]
fn person_text_reaches_the_focused_window_as_typed() {
    use x11rb::protocol::xproto::{
        CreateWindowAux, EventMask, InputFocus, KeyButMask, WindowClass,
    };
    use x11rb::protocol::Event;
    let xvfb = Xvfb::start();
    let display = xvfb.display.clone();
    let (app, screen) = x11rb::connect(Some(&display)).unwrap();
    let root = app.setup().roots[screen].root;
    let win = app.generate_id().unwrap();
    app.create_window(
        0,
        win,
        root,
        10,
        10,
        100,
        100,
        0,
        WindowClass::INPUT_OUTPUT,
        0,
        &CreateWindowAux::new().event_mask(EventMask::KEY_PRESS),
    )
    .unwrap();
    app.map_window(win).unwrap();
    app.set_input_focus(InputFocus::PARENT, win, x11rb::CURRENT_TIME).unwrap();
    app.sync().unwrap();

    let mut person = Injector::new(&display).unwrap();
    person.apply(&InputEvent::Pointer { x: 700, y: 500 }).unwrap();
    person.apply(&InputEvent::Text("é😀>a".into())).unwrap();
    // Shift held by the person must not change a character sent as text.
    person.apply(&InputEvent::Key { usage: 0x0007_00E1, down: true }).unwrap();
    person.apply(&InputEvent::Text("b".into())).unwrap();
    person.apply(&InputEvent::Key { usage: 0x0007_00E1, down: false }).unwrap();
    person.conn.sync().unwrap();

    let mut presses = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline {
        while let Some(event) = app.poll_for_event().unwrap() {
            if let Event::KeyPress(k) = event {
                presses.push((k.detail, u16::from(k.state)));
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    // Read the keys as a client does: the mapping now, the level from Shift.
    let setup = app.setup();
    let (min, count) = (setup.min_keycode, setup.max_keycode - setup.min_keycode + 1);
    let map = app.get_keyboard_mapping(min, count).unwrap().reply().unwrap();
    let per = usize::from(map.keysyms_per_keycode);
    let shift = u16::from(KeyButMask::SHIFT);
    let typed: Vec<u32> = presses
        .iter()
        .map(|&(code, state)| {
            let row = usize::from(code - min) * per;
            let level = usize::from(state & shift != 0);
            let sym = map.keysyms[row + level];
            if sym == 0 {
                map.keysyms[row]
            } else {
                sym
            }
        })
        .filter(|sym| !(0xffe1..=0xffee).contains(sym))
        .collect();
    person.release_all().unwrap();
    assert_eq!(typed, vec![0xe9, 0x0100_0000 + 0x1f600, 0x3e, 0x61, 0x62], "keysyms typed");
}

/// openbox on a test display, ended with the test. It reads no config of the host's
/// session: `--sm-disable` and an empty HOME for its rc lookup.
struct Openbox(std::process::Child);

impl Openbox {
    fn start(display: &str) -> Self {
        let home = std::env::temp_dir().join(format!("cmux-rd-openbox-{}", std::process::id()));
        std::fs::create_dir_all(&home).unwrap();
        let child = std::process::Command::new("openbox")
            .arg("--sm-disable")
            .env("DISPLAY", display)
            .env("HOME", &home)
            .env_remove("XDG_CONFIG_HOME")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("openbox");
        // openbox owns the screen once it holds WM_S0.
        let (conn, _) = x11rb::connect(Some(display)).unwrap();
        let atom = conn.intern_atom(false, b"WM_S0").unwrap().reply().unwrap().atom;
        let deadline = Instant::now() + Duration::from_secs(5);
        while conn.get_selection_owner(atom).unwrap().reply().unwrap().owner == x11rb::NONE {
            assert!(Instant::now() < deadline, "openbox took the screen");
            std::thread::sleep(Duration::from_millis(50));
        }
        Self(child)
    }
}

impl Drop for Openbox {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// On a real Xvfb: the person's XTest moves the person master, not the core pointer,
/// the property names the window under it, and ending the session removes the master.
/// `cargo test -- --ignored person_master` on a Linux host with Xvfb.
#[test]
#[ignore = "needs Xvfb; run with --ignored on a Linux host"]
fn person_master_keeps_the_core_pointer_for_the_agent() {
    use x11rb::protocol::xproto::{CreateWindowAux, WindowClass};
    let mut xvfb = Xvfb::start();
    let display = xvfb.display.clone();

    // The "agent": a second client whose XTest drives the core pointer.
    let (agent, screen) = x11rb::connect(Some(&display)).unwrap();
    let root = agent.setup().roots[screen].root;
    agent.xinput_xi_query_version(2, 2).unwrap().reply().unwrap();
    // A toplevel at (600,400)-(900,600) for the person to point at.
    let win = agent.generate_id().unwrap();
    agent
        .create_window(
            0,
            win,
            root,
            600,
            400,
            300,
            200,
            0,
            WindowClass::INPUT_OUTPUT,
            0,
            &CreateWindowAux::new(),
        )
        .unwrap();
    agent.map_window(win).unwrap();
    let core = |c: &RustConnection| {
        let r = c.query_pointer(root).unwrap().reply().unwrap();
        (r.root_x, r.root_y)
    };
    agent.xtest_fake_input(MOTION_NOTIFY_EVENT, 0, 0, root, 100, 100, 0).unwrap();
    agent.sync().unwrap();
    assert_eq!(core(&agent), (100, 100));

    let mut person = Injector::new(&display).unwrap();
    person.apply(&InputEvent::Pointer { x: 700, y: 500 }).unwrap();
    person.apply(&InputEvent::Button { button: 1, down: true }).unwrap();
    person.apply(&InputEvent::Button { button: 1, down: false }).unwrap();
    person.conn.sync().unwrap();
    let master = person.master().expect("person master");
    assert_ne!(master.pointer, 2, "the person master is not the core pointer");

    // The agent's core pointer did not move; the person's master is where they pointed.
    assert_eq!(core(&agent), (100, 100));
    let p = agent.xinput_xi_query_pointer(root, master.pointer).unwrap().reply().unwrap();
    assert_eq!((p.root_x >> 16, p.root_y >> 16), (700, 500));
    // The agent moves while the person holds control: the person's pointer stays.
    agent.xtest_fake_input(MOTION_NOTIFY_EVENT, 0, 0, root, 200, 150, 0).unwrap();
    agent.sync().unwrap();
    let p = agent.xinput_xi_query_pointer(root, master.pointer).unwrap().reply().unwrap();
    assert_eq!((p.root_x >> 16, p.root_y >> 16), (700, 500));
    assert_eq!(core(&agent), (200, 150));

    // The agent holds a button: the person's press waits until the agent lets go.
    let person_buttons = |c: &RustConnection| {
        let r = c.xinput_xi_query_pointer(root, master.pointer).unwrap().reply().unwrap();
        r.buttons.first().copied().unwrap_or(0) & 0x3fe
    };
    agent.xtest_fake_input(BUTTON_PRESS_EVENT, 1, 0, root, 0, 0, 0).unwrap();
    agent.sync().unwrap();
    assert!(Injector::agent_holds(&agent, root, master));
    person.apply(&InputEvent::Button { button: 1, down: true }).unwrap();
    person.conn.sync().unwrap();
    assert_eq!(person_buttons(&agent), 0, "the person's press waits");
    assert_eq!(person.pump().unwrap(), Some(HOLD_POLL), "still waiting");
    agent.xtest_fake_input(BUTTON_RELEASE_EVENT, 1, 0, root, 0, 0, 0).unwrap();
    agent.sync().unwrap();
    person.pump().unwrap();
    assert!(!person.hold.waiting(), "sent once the agent let go");
    person.conn.sync().unwrap();
    assert_ne!(person_buttons(&agent), 0, "the person's button is down now");
    person.apply(&InputEvent::Button { button: 1, down: false }).unwrap();
    person.conn.sync().unwrap();
    assert_eq!(person_buttons(&agent), 0);

    // The marker names the window under the person's pointer.
    let atom = agent.intern_atom(false, PERSON_PROPERTY.as_bytes()).unwrap().reply().unwrap().atom;
    let read = |c: &RustConnection| {
        let r =
            c.get_property(false, root, atom, AtomEnum::STRING, 0, 1024).unwrap().reply().unwrap();
        (!r.value.is_empty())
            .then(|| serde_json::from_slice::<serde_json::Value>(&r.value).unwrap())
    };
    let v = read(&agent).expect("marker while the person holds control");
    assert_eq!(v["window"], win);
    assert_eq!(v["pointer"], master.pointer);
    assert_eq!(v["button_held"], false);

    // A second injector (another session, or a restart) reuses the same master.
    let mut again = Injector::new(&display).unwrap();
    again.apply(&InputEvent::Pointer { x: 650, y: 450 }).unwrap();
    assert_eq!(again.master(), Some(master));
    drop(again);
    assert!(find_master(&agent, PERSON_MASTER).unwrap().is_some(), "still in use");

    // Ending the last session removes the master and the marker.
    drop(person);
    agent.sync().unwrap();
    assert_eq!(find_master(&agent, PERSON_MASTER).unwrap(), None);
    assert!(read(&agent).is_none());
    xvfb.alive();
}

/// Xvfb on a display it picks itself (-displayfd), killed when the test ends, passed
/// or failed.
pub(crate) struct Xvfb {
    child: std::process::Child,
    pub(crate) display: String,
}

impl Xvfb {
    pub(crate) fn start() -> Self {
        use std::io::BufRead;
        let mut child = std::process::Command::new("Xvfb")
            .args([
                "-displayfd",
                "1",
                "-screen",
                "0",
                "1280x800x24",
                "-nolisten",
                "tcp",
                "-noreset",
            ])
            .stdout(std::process::Stdio::piped())
            .spawn()
            .expect("Xvfb");
        let mut line = String::new();
        std::io::BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
        let n: u32 = line.trim().parse().expect("Xvfb printed its display");
        let mut xvfb = Self { child, display: format!(":{n}") };
        xvfb.alive();
        xvfb
    }

    pub(crate) fn alive(&mut self) {
        assert!(self.child.try_wait().expect("Xvfb status").is_none(), "Xvfb exited");
    }
}

impl Drop for Xvfb {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The crashing host for the next test: holds a button on the person master, then
/// aborts with no cleanup. Does nothing unless the next test runs it.
#[test]
#[ignore = "a helper process for crash_reuse_releases_a_crashed_hosts_button"]
fn crash_helper_holds_a_button_and_aborts() {
    let Ok(display) = std::env::var("CMUX_RD_CRASH_DISPLAY") else { return };
    let mut host = Injector::new(&display).unwrap();
    host.apply(&InputEvent::Pointer { x: 300, y: 300 }).unwrap();
    host.apply(&InputEvent::Button { button: 1, down: true }).unwrap();
    host.conn.sync().unwrap();
    std::process::abort();
}

/// A host that crashed holding a button leaves its master holding it (the server does
/// not release a dead client's XTest input). The next host replaces that master, so
/// nothing stays held.
#[test]
#[ignore = "needs Xvfb; run with --ignored on a Linux host"]
fn crash_reuse_releases_a_crashed_hosts_button() {
    let mut xvfb = Xvfb::start();
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "inject::tests::crash_helper_holds_a_button_and_aborts",
            "--include-ignored",
            "--nocapture",
        ])
        .env("CMUX_RD_CRASH_DISPLAY", &xvfb.display)
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(!status.success(), "the helper aborted");

    let (agent, screen) = x11rb::connect(Some(&xvfb.display)).unwrap();
    let root = agent.setup().roots[screen].root;
    agent.xinput_xi_query_version(2, 2).unwrap().reply().unwrap();
    let held = |c: &RustConnection, m: PersonMaster| {
        let r = c.xinput_xi_query_pointer(root, m.pointer).unwrap().reply().unwrap();
        r.buttons.first().copied().unwrap_or(0) & 0x3fe
    };
    let stale = find_master(&agent, PERSON_MASTER).unwrap().expect("the crashed host's master");
    assert_ne!(held(&agent, stale), 0, "the crashed host's button is still down");

    let mut host = Injector::new(&xvfb.display).unwrap();
    host.apply(&InputEvent::Pointer { x: 310, y: 310 }).unwrap();
    host.conn.sync().unwrap();
    let fresh = host.master().expect("a person master");
    assert_eq!(find_master(&agent, PERSON_MASTER).unwrap(), Some(fresh));
    assert_eq!(held(&agent, fresh), 0, "nothing stays held");
    let core = agent.xinput_xi_query_pointer(root, fresh.core).unwrap().reply().unwrap();
    assert_eq!(core.buttons.first().copied().unwrap_or(0) & 0x3fe, 0, "nor on the core pointer");
    drop(host);
    xvfb.alive();
}

/// The person's marker on `root`, if any.
fn marker(c: &RustConnection, root: Window) -> Option<serde_json::Value> {
    let atom = c.intern_atom(false, PERSON_PROPERTY.as_bytes()).unwrap().reply().unwrap().atom;
    let r = c.get_property(false, root, atom, AtomEnum::STRING, 0, 1024).unwrap().reply().unwrap();
    (!r.value.is_empty()).then(|| serde_json::from_slice(&r.value).unwrap())
}

fn connect(display: &str) -> (RustConnection, Window) {
    let (c, screen) = x11rb::connect(Some(display)).unwrap();
    let root = c.setup().roots[screen].root;
    c.xinput_xi_query_version(2, 2).unwrap().reply().unwrap();
    (c, root)
}

const KEY_A: u32 = 0x0007_0004;

/// Chromium takes keys from the last master keyboard only, so the master must not
/// outlast the person's input: it goes after PERSON_IDLE with nothing held, with the
/// marker, and the next input makes it again where the person's pointer was.
#[test]
#[ignore = "needs Xvfb; run with --ignored on a Linux host"]
fn person_master_goes_when_idle_and_comes_back_where_the_person_left() {
    let mut xvfb = Xvfb::start();
    let (agent, root) = connect(&xvfb.display);
    let mut person = Injector::new(&xvfb.display).unwrap();
    assert!(marker(&agent, root).is_none(), "nothing before the first input");
    person.apply(&InputEvent::Pointer { x: 700, y: 500 }).unwrap();
    person.conn.sync().unwrap();
    assert!(find_master(&agent, PERSON_MASTER).unwrap().is_some());
    assert!(marker(&agent, root).is_some(), "the marker comes with the master");
    let wake = person.pump().unwrap().expect("a wake for the idle check");
    assert!(wake <= PERSON_IDLE);

    // A held key keeps the master, however long.
    person.apply(&InputEvent::Key { usage: KEY_A, down: true }).unwrap();
    person.last_input = Some(Instant::now() - PERSON_IDLE * 2);
    assert_eq!(person.pump().unwrap(), None);
    assert!(person.master().is_some(), "a held key keeps the master");
    person.apply(&InputEvent::Key { usage: KEY_A, down: false }).unwrap();

    // Idle with nothing held: the master and the marker go together.
    person.last_input = Some(Instant::now() - PERSON_IDLE);
    assert_eq!(person.pump().unwrap(), None);
    agent.sync().unwrap();
    assert_eq!(person.master(), None);
    assert_eq!(find_master(&agent, PERSON_MASTER).unwrap(), None);
    assert!(marker(&agent, root).is_none());

    // The next input makes it again, with the pointer where the person left it.
    person.apply(&InputEvent::Key { usage: KEY_A, down: true }).unwrap();
    person.apply(&InputEvent::Key { usage: KEY_A, down: false }).unwrap();
    person.conn.sync().unwrap();
    let m = find_master(&agent, PERSON_MASTER).unwrap().expect("made again");
    assert_eq!(person.master(), Some(m));
    let p = agent.xinput_xi_query_pointer(root, m.pointer).unwrap().reply().unwrap();
    assert_eq!((p.root_x >> 16, p.root_y >> 16), (700, 500));
    assert!(marker(&agent, root).is_some());

    // Control ends: both go at once.
    person.release_all().unwrap();
    agent.sync().unwrap();
    assert_eq!(find_master(&agent, PERSON_MASTER).unwrap(), None);
    assert!(marker(&agent, root).is_none());
    xvfb.alive();
}

/// The marker's `button_held` covers a press waiting behind the agent's button.
#[test]
#[ignore = "needs Xvfb; run with --ignored on a Linux host"]
fn marker_shows_a_press_waiting_behind_the_agent() {
    let mut xvfb = Xvfb::start();
    let (agent, root) = connect(&xvfb.display);
    let mut person = Injector::new(&xvfb.display).unwrap();
    person.apply(&InputEvent::Pointer { x: 300, y: 300 }).unwrap();
    agent.xtest_fake_input(BUTTON_PRESS_EVENT, 1, 0, root, 0, 0, 0).unwrap();
    agent.sync().unwrap();
    person.apply(&InputEvent::Button { button: 1, down: true }).unwrap();
    person.conn.sync().unwrap();
    assert!(person.hold.waiting());
    assert_eq!(marker(&agent, root).unwrap()["button_held"], true);
    agent.xtest_fake_input(BUTTON_RELEASE_EVENT, 1, 0, root, 0, 0, 0).unwrap();
    agent.sync().unwrap();
    person.pump().unwrap();
    person.apply(&InputEvent::Button { button: 1, down: false }).unwrap();
    person.conn.sync().unwrap();
    assert_eq!(marker(&agent, root).unwrap()["button_held"], false);
    drop(person);
    xvfb.alive();
}

/// Stands in for another live host process for the next test.
#[test]
#[ignore = "a helper process for person_master_another_live_host_uses_is_kept"]
fn host_helper_sleeps() {
    if std::env::var_os("CMUX_RD_SLEEP_HELPER").is_some() {
        std::thread::sleep(Duration::from_secs(60));
    }
}

/// A master another live host lists is reused and never removed under it; once that
/// host is gone, the next host replaces it, so nothing it held stays held.
#[test]
#[ignore = "needs Xvfb; run with --ignored on a Linux host"]
fn person_master_another_live_host_uses_is_kept() {
    let mut xvfb = Xvfb::start();
    let (other, root) = connect(&xvfb.display);
    let mut helper = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "inject::tests::host_helper_sleeps", "--include-ignored"])
        .env("CMUX_RD_SLEEP_HELPER", "1")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    // The other host made the master, holds a button on it and lists its pid.
    let change = HierarchyChange {
        len: add_master_len(PERSON_MASTER),
        data: HierarchyChangeData::AddMaster(HierarchyChangeDataAddMaster {
            send_core: true,
            enable: true,
            name: PERSON_MASTER.as_bytes().to_vec(),
        }),
    };
    other.xinput_xi_change_hierarchy(&[change]).unwrap().check().unwrap();
    let theirs = find_master(&other, PERSON_MASTER).unwrap().unwrap();
    other.xinput_xi_set_client_pointer(x11rb::NONE, theirs.pointer).unwrap().check().unwrap();
    other.xtest_fake_input(BUTTON_PRESS_EVENT, 1, 0, root, 0, 0, 0).unwrap();
    let hosts = other.intern_atom(false, HOSTS_PROPERTY.as_bytes()).unwrap().reply().unwrap().atom;
    other
        .change_property32(PropMode::REPLACE, root, hosts, AtomEnum::CARDINAL, &[helper.id()])
        .unwrap();
    other.sync().unwrap();
    let held = |m: PersonMaster| {
        let r = other.xinput_xi_query_pointer(root, m.pointer).unwrap().reply().unwrap();
        r.buttons.first().copied().unwrap_or(0) & 0x3fe
    };
    assert_ne!(held(theirs), 0);

    let mut person = Injector::new(&xvfb.display).unwrap();
    person.apply(&InputEvent::Pointer { x: 400, y: 300 }).unwrap();
    person.conn.sync().unwrap();
    assert_eq!(person.master(), Some(theirs), "reused, not replaced");
    assert_ne!(held(theirs), 0, "the other host's button stays down");
    drop(person);
    other.sync().unwrap();
    assert_eq!(find_master(&other, PERSON_MASTER).unwrap(), Some(theirs), "kept for it");
    let listed =
        other.get_property(false, root, hosts, AtomEnum::CARDINAL, 0, 16).unwrap().reply().unwrap();
    assert_eq!(listed.value32().unwrap().collect::<Vec<_>>(), vec![helper.id()]);

    // The other host dies holding the button: the next host replaces the master.
    helper.kill().unwrap();
    helper.wait().unwrap();
    let mut next = Injector::new(&xvfb.display).unwrap();
    next.apply(&InputEvent::Pointer { x: 410, y: 310 }).unwrap();
    next.conn.sync().unwrap();
    let fresh = next.master().expect("a person master");
    assert_eq!(held(fresh), 0, "nothing stays held");
    drop(next);
    other.sync().unwrap();
    assert_eq!(find_master(&other, PERSON_MASTER).unwrap(), None);
    xvfb.alive();
}

/// A local page in Chrome on the Xvfb that reports every mousedown and click (with the
/// event's coordinates) to a loopback HTTP server, so a test can tell a click the page
/// got from one only sent.
struct ClickPage {
    chrome: std::process::Child,
    events: std::sync::Arc<Mutex<Vec<String>>>,
    _dir: std::path::PathBuf,
}

impl ClickPage {
    fn start(display: &str) -> Self {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let events = std::sync::Arc::new(Mutex::new(Vec::new()));
        let log = events.clone();
        std::thread::spawn(move || {
            const PAGE: &str = "<!doctype html><html><body style='margin:0;height:100vh;background:#3a6'>\
                <script>\
                const say = (k, e) => fetch('/ev?' + k + ',' + e.screenX + ',' + e.screenY + ',' + e.isTrusted, {cache: 'no-store'});\
                addEventListener('mousedown', e => say('down', e));\
                addEventListener('click', e => say('click', e));\
                addEventListener('load', () => fetch('/ev?ready,0,0,true'));\
                </script></body></html>";
            for stream in listener.incoming() {
                let Ok(mut s) = stream else { continue };
                let mut line = String::new();
                let _ = BufReader::new(&s).read_line(&mut line);
                let path = line.split_whitespace().nth(1).unwrap_or("").to_string();
                if let Some(ev) = path.strip_prefix("/ev?") {
                    log.lock().unwrap().push(ev.to_string());
                    let _ = write!(s, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n");
                } else {
                    let _ = write!(
                        s,
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{PAGE}",
                        PAGE.len()
                    );
                }
            }
        });
        let chrome_bin =
            std::env::var("CMUX_RD_TEST_CHROME").unwrap_or_else(|_| "google-chrome".into());
        let dir = std::env::temp_dir().join(format!("cmux-rd-clickpage-{}", std::process::id()));
        let chrome = std::process::Command::new(chrome_bin)
            .env("DISPLAY", display)
            .args([
                format!("--user-data-dir={}", dir.display()),
                "--no-first-run".into(),
                "--no-default-browser-check".into(),
                "--disable-gpu".into(),
                "--kiosk".into(),
                "--window-position=0,0".into(),
                "--window-size=1280,800".into(),
                format!("http://127.0.0.1:{port}/"),
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("google-chrome");
        let page = Self { chrome, events, _dir: dir };
        assert!(page.wait(Duration::from_secs(30), |e| e.iter().any(|x| x.starts_with("ready"))));
        // Kiosk Chrome maps after load on a slow host; give it a moment to take input.
        std::thread::sleep(Duration::from_millis(1500));
        page
    }

    fn wait(&self, limit: Duration, f: impl Fn(&[String]) -> bool) -> bool {
        let t = Instant::now();
        while t.elapsed() < limit {
            if f(&self.events.lock().unwrap()) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        false
    }

    fn clicks(&self) -> usize {
        count_clicks(&self.events.lock().unwrap())
    }

    /// Whether a click the agent makes now, with core XTest the way cmux-cua does, reaches
    /// the page within two seconds.
    fn agent_click_lands(&self, agent: &RustConnection, root: Window, x: i16, y: i16) -> bool {
        let before = self.clicks();
        agent.xtest_fake_input(MOTION_NOTIFY_EVENT, 0, 0, root, x, y, 0).unwrap();
        agent.xtest_fake_input(BUTTON_PRESS_EVENT, 1, 0, root, 0, 0, 0).unwrap();
        agent.xtest_fake_input(BUTTON_RELEASE_EVENT, 1, 0, root, 0, 0, 0).unwrap();
        agent.sync().unwrap();
        self.wait(Duration::from_secs(2), |e| count_clicks(e) > before)
    }
}

fn count_clicks(events: &[String]) -> usize {
    events.iter().filter(|e| e.starts_with("click")).count()
}

impl Drop for ClickPage {
    fn drop(&mut self) {
        let _ = self.chrome.kill();
        let _ = self.chrome.wait();
    }
}

/// The Cloud desktop journey: the person takes over (moves and clicks in the page) and,
/// while they hold control, the agent clicks the same page with core XTest. Both clicks
/// must reach Chrome. `cargo test -- --ignored agent_click_lands` on a Linux host with
/// Xvfb and Google Chrome.
#[test]
#[ignore = "needs Xvfb and Google Chrome; run with --ignored on a Linux host"]
fn agent_click_lands_in_chrome_while_the_person_holds_control() {
    agent_and_person_click_chrome(false);
}

/// The same under openbox, the window manager a Linux host's shared desktop runs.
#[test]
#[ignore = "needs Xvfb, openbox and Google Chrome; run with --ignored on a Linux host"]
fn agent_click_lands_in_chrome_while_the_person_holds_control_under_openbox() {
    agent_and_person_click_chrome(true);
}

fn agent_and_person_click_chrome(openbox: bool) {
    let mut xvfb = Xvfb::start();
    let _wm = openbox.then(|| Openbox::start(&xvfb.display));
    let (agent, root) = connect(&xvfb.display);
    let page = ClickPage::start(&xvfb.display);
    assert!(page.agent_click_lands(&agent, root, 350, 300), "baseline: no person");

    let mut person = Injector::new(&xvfb.display).unwrap();
    person.apply(&InputEvent::Pointer { x: 900, y: 600 }).unwrap();
    person.conn.sync().unwrap();
    assert!(person.master().is_some());
    let moved = page.agent_click_lands(&agent, root, 350, 300);

    let before = page.clicks();
    person.apply(&InputEvent::Button { button: 1, down: true }).unwrap();
    person.apply(&InputEvent::Button { button: 1, down: false }).unwrap();
    person.conn.sync().unwrap();
    let person_landed = page.wait(Duration::from_secs(2), |e| count_clicks(e) > before);
    let after_person_click = page.agent_click_lands(&agent, root, 350, 300);
    eprintln!(
        "events: {:?}\nagent after person moved: {moved}; person click: {person_landed}; agent after person clicked: {after_person_click}",
        page.events.lock().unwrap()
    );
    assert!(person_landed, "the person's click reaches Chrome");
    assert!(moved, "the agent's click lands while the person's pointer is in the page");
    assert!(after_person_click, "the agent's click lands after the person clicked");
    xvfb.alive();
}
