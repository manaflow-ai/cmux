//! Input injection with XTest for `cmux.rd/1` input events. Tracks pressed keys and
//! buttons so they can all be released when control ends or an event was lost.
//!
//! The person drives their own pointer. An agent on the same display (cmux-cua) injects
//! with core XTest, which the X server routes through the sending client's ClientPointer,
//! by default the Virtual core pointer (Xext/xtest.c: PickPointer, then GetXTestDevice).
//! Before the first event, the injector finds the XI2 master named [`PERSON_MASTER`] or
//! adds it, and makes it this connection's ClientPointer. From then on the person's XTest
//! events move that master and type on its paired keyboard, and the agent keeps the core
//! pointer, so both work at once. The master is reused after a crash (found by name) and
//! removed when the last injector in this process ends.
//!
//! While the person holds control, the root window carries [`PERSON_PROPERTY`]: JSON with
//! the toplevel under the person's pointer and the time of their last input. An agent can
//! read it to wait only when it would act on the window the person is using. The property
//! goes away with the master; after a crash its `last_input_unix_ms` simply stops moving.
//!
//! Chrome drops both clicks when one master presses while the other holds a button (the
//! staging spike: the agent pressed, the person clicked 150 ms later, Chrome saw only the
//! agent's mousedown). So a person's press waits while the core (agent) pointer holds a
//! button, at most [`HOLD_LIMIT`], with every later event queued behind it in order; the
//! property's `button_held` tells the agent the same about the person.

use crate::keymap::hid_to_x;
use crate::Res;
use cmux_rd_proto::InputEvent;
use std::collections::{BTreeSet, VecDeque};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use x11rb::connection::Connection;
use x11rb::protocol::xinput::{
    self, ChangeMode, ConnectionExt as _, DeviceType, HierarchyChange, HierarchyChangeData,
    HierarchyChangeDataAddMaster, HierarchyChangeDataRemoveMaster,
};
use x11rb::protocol::xproto::{
    Atom, AtomEnum, ConnectionExt as _, PropMode, Window, BUTTON_PRESS_EVENT,
    BUTTON_RELEASE_EVENT, KEY_PRESS_EVENT, KEY_RELEASE_EVENT, MOTION_NOTIFY_EVENT,
};
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

/// The XI2 master the person's input goes through (`NAME pointer` / `NAME keyboard`).
pub const PERSON_MASTER: &str = "cmux person";
/// Root window property (STRING, JSON) naming the window the person is using.
pub const PERSON_PROPERTY: &str = "_CMUX_RD_PERSON";
/// Motion refreshes the property at most this often; presses and keys always do.
const PROPERTY_EVERY: Duration = Duration::from_millis(200);
/// A person's press waits at most this long for the agent's held button.
pub const HOLD_LIMIT: Duration = Duration::from_secs(2);
/// Events queued behind a waiting press before the queue is sent anyway.
const HOLD_QUEUE_MAX: usize = 512;

/// Injectors in this process that hold the person master; the last one removes it.
static PERSON_USERS: Mutex<usize> = Mutex::new(0);

/// The person master's device ids on the server.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct PersonMaster {
    pointer: u16,
    keyboard: u16,
    /// The core pointer the agent's XTest drives (0 when not found).
    core: u16,
}

/// True for events that press a button: a press, or a scroll (wheel buttons 4 to 7).
fn presses(event: &InputEvent) -> bool {
    match event {
        InputEvent::Button { down, .. } => *down,
        InputEvent::Scroll { dx, dy, .. } => dx.unsigned_abs() >= 100 || dy.unsigned_abs() >= 100,
        _ => false,
    }
}

/// Holds a person's press (and everything after it, in order) while the agent holds a
/// button, for at most [`HOLD_LIMIT`]. Pure, so the timing is tested without X.
#[derive(Default)]
struct HoldGuard {
    queue: VecDeque<InputEvent>,
    since: Option<Instant>,
}

impl HoldGuard {
    /// Queues `event` and returns the events to inject now.
    fn push(
        &mut self,
        event: InputEvent,
        now: Instant,
        agent_holds: impl FnMut() -> bool,
    ) -> Vec<InputEvent> {
        self.queue.push_back(event);
        if self.queue.len() > HOLD_QUEUE_MAX {
            self.since = None;
            return self.queue.drain(..).collect();
        }
        self.release(now, agent_holds)
    }

    /// The events that may go now: everything up to a press the agent's held button
    /// still blocks.
    fn release(&mut self, now: Instant, mut agent_holds: impl FnMut() -> bool) -> Vec<InputEvent> {
        let mut out = Vec::new();
        while let Some(front) = self.queue.front() {
            if presses(front) {
                let waited = self.since.map_or(Duration::ZERO, |s| now.saturating_duration_since(s));
                if waited < HOLD_LIMIT && agent_holds() {
                    self.since.get_or_insert(now);
                    break;
                }
                self.since = None;
            }
            out.extend(self.queue.pop_front());
        }
        out
    }

    fn waiting(&self) -> bool {
        !self.queue.is_empty()
    }

    fn clear(&mut self) {
        self.queue.clear();
        self.since = None;
    }
}

pub struct Injector {
    conn: RustConnection,
    root: Window,
    keys: BTreeSet<u8>,
    buttons: BTreeSet<u8>,
    /// None until the first event; Some(None) when XI2 masters are unavailable (the
    /// person then drives the core pointer, as before).
    person: Option<Option<PersonMaster>>,
    property: Option<Atom>,
    last_property: Option<Instant>,
    hold: HoldGuard,
    /// Events with no XTest mapping (for example text), counted for stats.
    pub unsupported: u64,
}

impl Injector {
    pub fn new(display: &str) -> Res<Self> {
        let (conn, screen_num) = x11rb::connect(Some(display))?;
        let root = conn.setup().roots[screen_num].root;
        conn.xtest_get_version(2, 2)?.reply()?;
        Ok(Self {
            conn,
            root,
            keys: BTreeSet::new(),
            buttons: BTreeSet::new(),
            person: None,
            property: None,
            last_property: None,
            hold: HoldGuard::default(),
            unsupported: 0,
        })
    }

    fn fake(&self, ty: u8, detail: u8, x: i32, y: i32) -> Res<()> {
        let (x, y) =
            (x.clamp(0, i32::from(i16::MAX)) as i16, y.clamp(0, i32::from(i16::MAX)) as i16);
        self.conn.xtest_fake_input(ty, detail, x11rb::CURRENT_TIME, self.root, x, y, 0)?;
        Ok(())
    }

    /// The person master, set as this connection's ClientPointer on first use.
    fn person(&mut self) -> Option<PersonMaster> {
        if let Some(p) = self.person {
            return p;
        }
        let p = match attach_person_master(&self.conn) {
            Ok(m) => {
                *PERSON_USERS.lock().unwrap() += 1;
                self.property = self
                    .conn
                    .intern_atom(false, PERSON_PROPERTY.as_bytes())
                    .ok()
                    .and_then(|c| c.reply().ok())
                    .map(|r| r.atom);
                Some(m)
            }
            Err(e) => {
                eprintln!(
                    "cmux-rd host: no XI2 master for the person ({e}); input drives the core pointer"
                );
                None
            }
        };
        self.person = Some(p);
        p
    }

    /// Records the toplevel under the person's pointer and the time on the root window.
    fn note_person(&mut self, master: PersonMaster, always: bool) {
        let Some(atom) = self.property else { return };
        if !always && self.last_property.is_some_and(|t| t.elapsed() < PROPERTY_EVERY) {
            return;
        }
        self.last_property = Some(Instant::now());
        let window = self
            .conn
            .xinput_xi_query_pointer(self.root, master.pointer)
            .ok()
            .and_then(|c| c.reply().ok())
            .map(|r| r.child)
            .unwrap_or(0);
        let body = person_property(master, window, !self.buttons.is_empty(), unix_ms());
        let _ = self.conn.change_property8(
            PropMode::REPLACE,
            self.root,
            atom,
            AtomEnum::STRING,
            body.as_bytes(),
        );
    }

    /// Whether the agent's core pointer holds a button now.
    fn agent_holds(conn: &RustConnection, root: Window, master: PersonMaster) -> bool {
        if master.core == 0 {
            return false;
        }
        conn.xinput_xi_query_pointer(root, master.core)
            .ok()
            .and_then(|c| c.reply().ok())
            .is_some_and(|r| r.buttons.first().is_some_and(|m| m & 0x3fe != 0))
    }

    /// Injects one event (or queues it behind a press the agent's held button blocks)
    /// and flushes.
    pub fn apply(&mut self, event: &InputEvent) -> Res<()> {
        let Some(master) = self.person() else { return self.send(event, None) };
        let (conn, root) = (&self.conn, self.root);
        let ready = self.hold.push(event.clone(), Instant::now(), || Self::agent_holds(conn, root, master));
        for e in &ready {
            self.send(e, Some(master))?;
        }
        Ok(())
    }

    /// Injects queued events whose press the agent no longer blocks (or that waited
    /// [`HOLD_LIMIT`]). Returns true while events still wait.
    pub fn pump(&mut self) -> Res<bool> {
        if !self.hold.waiting() {
            return Ok(false);
        }
        let Some(Some(master)) = self.person else { return Ok(false) };
        let (conn, root) = (&self.conn, self.root);
        let ready = self.hold.release(Instant::now(), || Self::agent_holds(conn, root, master));
        for e in &ready {
            self.send(e, Some(master))?;
        }
        Ok(self.hold.waiting())
    }

    fn send(&mut self, event: &InputEvent, person: Option<PersonMaster>) -> Res<()> {
        let mut pressed = false;
        match event {
            InputEvent::Key { usage, down } => match hid_to_x(*usage) {
                Some(code) => {
                    self.fake(if *down { KEY_PRESS_EVENT } else { KEY_RELEASE_EVENT }, code, 0, 0)?;
                    if *down {
                        self.keys.insert(code);
                        pressed = true;
                    } else {
                        self.keys.remove(&code);
                    }
                }
                None => self.unsupported += 1,
            },
            InputEvent::Pointer { x, y } => self.fake(MOTION_NOTIFY_EVENT, 0, *x, *y)?,
            InputEvent::Button { button, down } => {
                let b = (*button).clamp(1, 9);
                self.fake(if *down { BUTTON_PRESS_EVENT } else { BUTTON_RELEASE_EVENT }, b, 0, 0)?;
                if *down {
                    self.buttons.insert(b);
                } else {
                    self.buttons.remove(&b);
                }
                pressed = true;
            }
            InputEvent::Scroll { dx, dy, .. } => {
                // X scrolls in wheel clicks: buttons 4/5 vertical, 6/7 horizontal, one per 100 units.
                for (amount, neg, pos) in [(*dy, 4u8, 5u8), (*dx, 6u8, 7u8)] {
                    let clicks = (amount.unsigned_abs() / 100).min(20);
                    let button = if amount < 0 { neg } else { pos };
                    for _ in 0..clicks {
                        self.fake(BUTTON_PRESS_EVENT, button, 0, 0)?;
                        self.fake(BUTTON_RELEASE_EVENT, button, 0, 0)?;
                    }
                }
                pressed = true;
            }
            // Desktop sessions do not offer the input.service cap.
            InputEvent::Text(_) | InputEvent::Service { .. } => self.unsupported += 1,
        }
        if let Some(m) = person {
            self.note_person(m, pressed);
        }
        self.conn.flush()?;
        Ok(())
    }

    /// Releases every key and button this injector pressed.
    pub fn release_all(&mut self) -> Res<()> {
        self.hold.clear();
        for code in std::mem::take(&mut self.keys) {
            self.fake(KEY_RELEASE_EVENT, code, 0, 0)?;
        }
        for b in std::mem::take(&mut self.buttons) {
            self.fake(BUTTON_RELEASE_EVENT, b, 0, 0)?;
        }
        self.conn.flush()?;
        Ok(())
    }
}

impl Drop for Injector {
    fn drop(&mut self) {
        let _ = self.release_all();
        let Some(Some(master)) = self.person else { return };
        let mut users = PERSON_USERS.lock().unwrap();
        *users = users.saturating_sub(1);
        if *users > 0 {
            return;
        }
        if let Some(atom) = self.property {
            let _ = self.conn.delete_property(self.root, atom);
        }
        let _ = remove_person_master(&self.conn, master);
        let _ = self.conn.sync();
    }
}

fn unix_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// The [`PERSON_PROPERTY`] value. `window` is the root child under the person's pointer
/// (0 when none); the host pid lets a reader tell a live host from a crashed one.
fn person_property(
    master: PersonMaster,
    window: Window,
    button_held: bool,
    last_input_unix_ms: u64,
) -> String {
    serde_json::json!({
        "v": 1,
        "pid": std::process::id(),
        "pointer": master.pointer,
        "keyboard": master.keyboard,
        "window": window,
        "button_held": button_held,
        "last_input_unix_ms": last_input_unix_ms,
    })
    .to_string()
}

/// The 4-byte length of an XIAddMaster change: type, len, name_len, send_core, enable,
/// then the name padded to 4.
fn add_master_len(name: &str) -> u16 {
    ((8 + name.len().div_ceil(4) * 4) / 4) as u16
}

/// Finds the master pointer and keyboard named `name` (`NAME pointer`, `NAME keyboard`).
fn find_master(conn: &RustConnection, name: &str) -> Res<Option<PersonMaster>> {
    let infos = conn.xinput_xi_query_device(u16::from(xinput::Device::ALL))?.reply()?.infos;
    let devices: Vec<(u16, DeviceType, u16, Vec<u8>)> =
        infos.into_iter().map(|d| (d.deviceid, d.type_, d.attachment, d.name)).collect();
    Ok(pick_master(&devices, name))
}

/// The master pair named `name` among (id, type, attachment, name) rows.
fn pick_master(devices: &[(u16, DeviceType, u16, Vec<u8>)], name: &str) -> Option<PersonMaster> {
    let want = format!("{name} pointer");
    let (pointer, _, keyboard, _) = devices
        .iter()
        .find(|(_, ty, _, n)| *ty == DeviceType::MASTER_POINTER && n.as_slice() == want.as_bytes())?;
    let core = devices
        .iter()
        .find(|(_, ty, _, n)| *ty == DeviceType::MASTER_POINTER && n.as_slice() == b"Virtual core pointer")
        .map_or(0, |(id, ..)| *id);
    devices
        .iter()
        .any(|(id, ty, _, _)| id == keyboard && *ty == DeviceType::MASTER_KEYBOARD)
        .then_some(PersonMaster { pointer: *pointer, keyboard: *keyboard, core })
}

/// Finds or adds the person master and makes it `conn`'s ClientPointer.
fn attach_person_master(conn: &RustConnection) -> Res<PersonMaster> {
    let v = conn.xinput_xi_query_version(2, 2)?.reply()?;
    if v.major_version < 2 {
        return Err(format!("XInput {}.{} has no masters", v.major_version, v.minor_version).into());
    }
    let master = match find_master(conn, PERSON_MASTER)? {
        Some(m) => m,
        None => {
            let change = HierarchyChange {
                len: add_master_len(PERSON_MASTER),
                data: HierarchyChangeData::AddMaster(HierarchyChangeDataAddMaster {
                    send_core: true,
                    enable: true,
                    name: PERSON_MASTER.as_bytes().to_vec(),
                }),
            };
            conn.xinput_xi_change_hierarchy(&[change])?.check()?;
            find_master(conn, PERSON_MASTER)?.ok_or("the added master is not listed")?
        }
    };
    conn.xinput_xi_set_client_pointer(x11rb::NONE, master.pointer)?.check()?;
    Ok(master)
}

/// Removes the person master; its slaves go back to the core devices.
fn remove_person_master(conn: &RustConnection, master: PersonMaster) -> Res<()> {
    let infos = conn.xinput_xi_query_device(u16::from(xinput::Device::ALL_MASTER))?.reply()?.infos;
    // The Virtual core devices by name, else any other master of that type.
    let core = |ty: DeviceType, name: &[u8]| {
        let other = |d: &&xinput::XIDeviceInfo| {
            d.type_ == ty && d.deviceid != master.pointer && d.deviceid != master.keyboard
        };
        infos.iter().filter(other).find(|d| d.name == name).or_else(|| infos.iter().find(other))
    };
    let (Some(p), Some(k)) = (
        core(DeviceType::MASTER_POINTER, b"Virtual core pointer"),
        core(DeviceType::MASTER_KEYBOARD, b"Virtual core keyboard"),
    )
    else {
        return Err("no other master to return the slaves to".into());
    };
    let change = HierarchyChange {
        len: 3,
        data: HierarchyChangeData::RemoveMaster(HierarchyChangeDataRemoveMaster {
            deviceid: master.pointer,
            return_mode: ChangeMode::ATTACH,
            return_pointer: p.deviceid,
            return_keyboard: k.deviceid,
        }),
    };
    conn.xinput_xi_change_hierarchy(&[change])?.check()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

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
            Some(PersonMaster { pointer: 11, keyboard: 12, core: 2 })
        );
        assert_eq!(pick_master(&rows, "agent"), None);
        assert_eq!(pick_master(&rows[..3], PERSON_MASTER), None);
    }

    #[test]
    fn person_property_is_versioned_json() {
        let v: serde_json::Value = serde_json::from_str(&person_property(
            PersonMaster { pointer: 11, keyboard: 12, core: 2 },
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

    /// On a real Xvfb: the person's XTest moves the person master, not the core pointer,
    /// the property names the window under it, and ending the session removes the master.
    /// `cargo test -- --ignored person_master` on a Linux host with Xvfb.
    #[test]
    #[ignore = "needs Xvfb; run with --ignored on a Linux host"]
    fn person_master_keeps_the_core_pointer_for_the_agent() {
        use x11rb::protocol::xproto::{CreateWindowAux, WindowClass};
        let display = format!(":{}", 60 + std::process::id() % 30);
        let mut xvfb = std::process::Command::new("Xvfb")
            .args([display.as_str(), "-screen", "0", "1280x800x24", "-nolisten", "tcp", "-noreset"])
            .spawn()
            .expect("Xvfb");
        let socket = format!("/tmp/.X11-unix/X{}", &display[1..]);
        let t0 = Instant::now();
        while !std::path::Path::new(&socket).exists() {
            assert!(t0.elapsed() < Duration::from_secs(10), "Xvfb did not start");
            std::thread::sleep(Duration::from_millis(50));
        }
        std::thread::sleep(Duration::from_millis(200));

        // The "agent": a second client whose XTest drives the core pointer.
        let (agent, screen) = x11rb::connect(Some(&display)).unwrap();
        let root = agent.setup().roots[screen].root;
        agent.xinput_xi_query_version(2, 2).unwrap().reply().unwrap();
        // A toplevel at (600,400)-(900,600) for the person to point at.
        let win = agent.generate_id().unwrap();
        agent
            .create_window(0, win, root, 600, 400, 300, 200, 0, WindowClass::INPUT_OUTPUT, 0, &CreateWindowAux::new())
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
        let master = person.person.flatten().expect("person master");
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
        assert!(person.pump().unwrap(), "still waiting");
        agent.xtest_fake_input(BUTTON_RELEASE_EVENT, 1, 0, root, 0, 0, 0).unwrap();
        agent.sync().unwrap();
        assert!(!person.pump().unwrap(), "sent once the agent let go");
        person.conn.sync().unwrap();
        assert_ne!(person_buttons(&agent), 0, "the person's button is down now");
        person.apply(&InputEvent::Button { button: 1, down: false }).unwrap();
        person.conn.sync().unwrap();
        assert_eq!(person_buttons(&agent), 0);

        // The marker names the window under the person's pointer.
        let atom = agent.intern_atom(false, PERSON_PROPERTY.as_bytes()).unwrap().reply().unwrap().atom;
        let read = |c: &RustConnection| {
            let r = c.get_property(false, root, atom, AtomEnum::STRING, 0, 1024).unwrap().reply().unwrap();
            (!r.value.is_empty()).then(|| serde_json::from_slice::<serde_json::Value>(&r.value).unwrap())
        };
        let v = read(&agent).expect("marker while the person holds control");
        assert_eq!(v["window"], win);
        assert_eq!(v["pointer"], master.pointer);
        assert_eq!(v["button_held"], false);

        // A second injector (another session, or a restart) reuses the same master.
        let mut again = Injector::new(&display).unwrap();
        again.apply(&InputEvent::Pointer { x: 650, y: 450 }).unwrap();
        assert_eq!(again.person.flatten(), Some(master));
        drop(again);
        assert!(find_master(&agent, PERSON_MASTER).unwrap().is_some(), "still in use");

        // Ending the last session removes the master and the marker.
        drop(person);
        agent.sync().unwrap();
        assert_eq!(find_master(&agent, PERSON_MASTER).unwrap(), None);
        assert!(read(&agent).is_none());

        let _ = xvfb.kill();
        let _ = xvfb.wait();
    }
}
