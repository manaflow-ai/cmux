//! Input injection with XTest for `cmux.rd/1` input events. Tracks pressed keys and
//! buttons so they can all be released when control ends or an event was lost.
//!
//! The person drives their own pointer. An agent on the same display (cmux-cua) injects
//! with core XTest, which the X server routes through the sending client's ClientPointer,
//! by default the Virtual core pointer (Xext/xtest.c: PickPointer, then GetXTestDevice).
//! On the person's first event, the injector finds the XI2 master named [`PERSON_MASTER`]
//! or adds it, and makes it this connection's ClientPointer. From then on the person's
//! XTest events move that master and type on its paired keyboard, and the agent keeps the
//! core pointer, so both work at once.
//!
//! The master exists only while the person is acting. Chromium takes key events from one
//! master keyboard only, the last one listed (ui/events/devices/x11/touch_factory_x11.cc),
//! so while it exists the agent's keys into Chrome are lost. So it is removed after
//! [`PERSON_IDLE`] with no input and nothing held, and when control ends, and made again
//! on the person's next event, at the pointer position they left.
//!
//! The root window carries [`PERSON_PROPERTY`] exactly while the master exists: JSON with
//! the toplevel under the person's pointer, whether they hold (or wait to press) a button,
//! and the time of their last input. An agent waits while it exists before it types into
//! Chromium, and before it clicks the window the person is using.
//!
//! Hosts that use the master list their pids in [`HOSTS_PROPERTY`], changed under a server
//! grab. Only the last live host removes the master. One left by a crashed host (no live
//! host listed) is removed and made again, because the server does not release what a dead
//! client held through XTest, and removing a device does (dix DisableDevice:
//! ReleaseButtonsAndKeys).
//!
//! Chrome drops both clicks when one master presses while the other holds a button (the
//! staging spike: the agent pressed, the person clicked 150 ms later, Chrome saw only the
//! agent's mousedown). So a person's press waits while the core (agent) pointer holds a
//! button, at most [`HOLD_LIMIT`] from when it arrived, with every later event queued
//! behind it in order; the property's `button_held` tells the agent the same about the
//! person.

use crate::keymap::hid_to_x;
use crate::Res;
use cmux_rd_proto::InputEvent;
use std::collections::{BTreeSet, HashMap, VecDeque};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use x11rb::connection::Connection;
use x11rb::protocol::xinput::{
    self, ChangeMode, ConnectionExt as _, DeviceType, HierarchyChange, HierarchyChangeData,
    HierarchyChangeDataAddMaster, HierarchyChangeDataRemoveMaster,
};
use x11rb::protocol::xproto::{
    Atom, AtomEnum, ConnectionExt as _, PropMode, Window, BUTTON_PRESS_EVENT, BUTTON_RELEASE_EVENT,
    KEY_PRESS_EVENT, KEY_RELEASE_EVENT, MOTION_NOTIFY_EVENT,
};
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

/// The XI2 master the person's input goes through (`NAME pointer` / `NAME keyboard`).
pub const PERSON_MASTER: &str = "cmux person";
/// Root window property (STRING, JSON) naming the window the person is using; it exists
/// exactly while the person master does.
pub const PERSON_PROPERTY: &str = "_CMUX_RD_PERSON";
/// Root window property (CARDINAL[]) listing the pids of the hosts using the person master.
pub const HOSTS_PROPERTY: &str = "_CMUX_RD_PERSON_HOSTS";
/// Motion refreshes the property at most this often; buttons, scrolls and keys always do.
const PROPERTY_EVERY: Duration = Duration::from_millis(200);
/// A person's press waits at most this long (from its arrival) for the agent's held button.
pub const HOLD_LIMIT: Duration = Duration::from_secs(2);
/// How often a waiting press checks the agent's buttons again.
const HOLD_POLL: Duration = Duration::from_millis(20);
/// Events queued behind a waiting press before the queue is sent anyway.
const HOLD_QUEUE_MAX: usize = 512;
/// With no input for this long and nothing held, the person master is removed.
pub const PERSON_IDLE: Duration = Duration::from_secs(3);

/// Injectors in this process holding the person master, per display; the last one removes
/// it. Held across find-or-create and removal, so they never race.
static PERSON_USERS: Mutex<Option<HashMap<String, usize>>> = Mutex::new(None);

/// The person master's device ids on the server.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct PersonMaster {
    pointer: u16,
    keyboard: u16,
    /// The core pointer the agent's XTest drives (0 when not found).
    core: u16,
}

/// Whether this injector holds the person master.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Person {
    /// Not now: made on the next event.
    Detached,
    /// XI2 masters are unavailable; the person drives the core pointer, as before.
    Unavailable,
    Attached(PersonMaster),
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
/// button, each press for at most [`HOLD_LIMIT`] from when it arrived. Pure, so the timing
/// is tested without X.
#[derive(Default)]
struct HoldGuard {
    queue: VecDeque<(InputEvent, Instant)>,
}

impl HoldGuard {
    /// Queues `event` (arrived at `now`) and returns the events to inject now.
    fn push(
        &mut self,
        event: InputEvent,
        now: Instant,
        agent_holds: impl FnMut() -> bool,
    ) -> Vec<InputEvent> {
        self.queue.push_back((event, now));
        if self.queue.len() > HOLD_QUEUE_MAX {
            return self.queue.drain(..).map(|(e, _)| e).collect();
        }
        self.release(now, agent_holds)
    }

    /// The events that may go now: everything up to a press the agent's held button
    /// still blocks.
    fn release(&mut self, now: Instant, mut agent_holds: impl FnMut() -> bool) -> Vec<InputEvent> {
        let mut out = Vec::new();
        while let Some((front, arrived)) = self.queue.front() {
            if presses(front)
                && now.saturating_duration_since(*arrived) < HOLD_LIMIT
                && agent_holds()
            {
                break;
            }
            out.extend(self.queue.pop_front().map(|(e, _)| e));
        }
        out
    }

    fn waiting(&self) -> bool {
        !self.queue.is_empty()
    }

    fn clear(&mut self) {
        self.queue.clear();
    }
}

pub struct Injector {
    conn: RustConnection,
    display: String,
    root: Window,
    keys: BTreeSet<u8>,
    buttons: BTreeSet<u8>,
    person: Person,
    property: Atom,
    hosts: Atom,
    last_property: Option<Instant>,
    /// Motion moved the pointer since the property was last written.
    property_stale: bool,
    /// The person's last event, for [`PERSON_IDLE`].
    last_input: Option<Instant>,
    /// Where the person's pointer was last sent, restored when the master is made again.
    last_pointer: Option<(i32, i32)>,
    hold: HoldGuard,
    /// Events with no XTest mapping (for example text), counted for stats.
    pub unsupported: u64,
}

impl Injector {
    pub fn new(display: &str) -> Res<Self> {
        let (conn, screen_num) = x11rb::connect(Some(display))?;
        let root = conn.setup().roots[screen_num].root;
        conn.xtest_get_version(2, 2)?.reply()?;
        let property = conn.intern_atom(false, PERSON_PROPERTY.as_bytes())?.reply()?.atom;
        let hosts = conn.intern_atom(false, HOSTS_PROPERTY.as_bytes())?.reply()?.atom;
        Ok(Self {
            conn,
            display: display.to_owned(),
            root,
            keys: BTreeSet::new(),
            buttons: BTreeSet::new(),
            person: Person::Detached,
            property,
            hosts,
            last_property: None,
            property_stale: false,
            last_input: None,
            last_pointer: None,
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

    /// The person master, attached (made if needed, set as this connection's
    /// ClientPointer, the pointer put back where the person left it) when detached.
    fn person(&mut self) -> Option<PersonMaster> {
        match self.person {
            Person::Attached(m) => return Some(m),
            Person::Unavailable => return None,
            Person::Detached => {}
        }
        let mut guard = PERSON_USERS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let users = guard.get_or_insert_with(HashMap::new).entry(self.display.clone()).or_insert(0);
        let mine = *users > 0;
        let attached = self.attach(mine).or_else(|e| {
            eprintln!("cmux-rd host: attaching the person master failed ({e}); trying once more");
            self.attach(mine)
        });
        match attached {
            Ok(m) => {
                *users += 1;
                drop(guard);
                self.person = Person::Attached(m);
                if let Some((x, y)) = self.last_pointer {
                    if let Err(e) = self.fake(MOTION_NOTIFY_EVENT, 0, x, y) {
                        eprintln!("cmux-rd host: restoring the person's pointer failed: {e}");
                    }
                }
                self.note_person(m, true);
                Some(m)
            }
            Err(e) => {
                eprintln!(
                    "cmux-rd host: no XI2 master for the person ({e}); input drives the core pointer"
                );
                self.person = Person::Unavailable;
                None
            }
        }
    }

    /// Finds or adds the person master under a server grab, lists this host in
    /// [`HOSTS_PROPERTY`] and makes the master this connection's ClientPointer. `mine`:
    /// another injector in this process uses it. Otherwise one that no live host lists is
    /// a crashed host's and may still hold a button; it is removed and made again.
    fn attach(&self, mine: bool) -> Res<PersonMaster> {
        let v = self.conn.xinput_xi_query_version(2, 2)?.reply()?;
        if v.major_version < 2 {
            return Err(
                format!("XInput {}.{} has no masters", v.major_version, v.minor_version).into()
            );
        }
        let master = self.grabbed(|this| {
            let mut hosts = this.live_hosts()?;
            let mut found = find_master(&this.conn, PERSON_MASTER)?;
            if let (false, true, Some(stale)) = (mine, hosts.is_empty(), found) {
                match remove_person_master(&this.conn, stale) {
                    Ok(()) => found = None,
                    Err(e) => eprintln!(
                        "cmux-rd host: removing a crashed host's person master failed: {e}"
                    ),
                }
            }
            let master = match found {
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
                    this.conn.xinput_xi_change_hierarchy(&[change])?.check()?;
                    find_master(&this.conn, PERSON_MASTER)?
                        .ok_or("the added master is not listed")?
                }
            };
            hosts.push(std::process::id());
            this.conn.change_property32(
                PropMode::REPLACE,
                this.root,
                this.hosts,
                AtomEnum::CARDINAL,
                &hosts,
            )?;
            Ok(master)
        })?;
        self.conn.xinput_xi_set_client_pointer(x11rb::NONE, master.pointer)?.check()?;
        Ok(master)
    }

    /// Drops this injector's hold on the person master. The last injector in this process
    /// takes this host off [`HOSTS_PROPERTY`]; when no live host is left, the master and
    /// [`PERSON_PROPERTY`] go. Call with nothing held.
    fn detach(&mut self) {
        let Person::Attached(_) = self.person else { return };
        self.person = Person::Detached;
        self.property_stale = false;
        self.last_property = None;
        let mut guard = PERSON_USERS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let users = guard.get_or_insert_with(HashMap::new).entry(self.display.clone()).or_insert(0);
        *users = users.saturating_sub(1);
        if *users > 0 {
            return;
        }
        let done = self.grabbed(|this| {
            let hosts = this.live_hosts()?;
            if !hosts.is_empty() {
                // Another live host still uses it.
                this.conn.change_property32(
                    PropMode::REPLACE,
                    this.root,
                    this.hosts,
                    AtomEnum::CARDINAL,
                    &hosts,
                )?;
                return Ok(());
            }
            this.conn.delete_property(this.root, this.hosts)?;
            this.conn.delete_property(this.root, this.property)?;
            match find_master(&this.conn, PERSON_MASTER)? {
                Some(m) => remove_person_master(&this.conn, m),
                None => Ok(()),
            }
        });
        drop(guard);
        if let Err(e) = done {
            eprintln!("cmux-rd host: removing the person master failed: {e}");
        }
        let _ = self.conn.sync();
    }

    /// Runs `f` with the server grabbed, so hosts in other processes see its changes to
    /// the master and [`HOSTS_PROPERTY`] whole.
    fn grabbed<T>(&self, f: impl FnOnce(&Self) -> Res<T>) -> Res<T> {
        self.conn.grab_server()?;
        let out = f(self);
        let ungrab = (|| -> Res<()> {
            self.conn.ungrab_server()?;
            self.conn.sync()?;
            Ok(())
        })();
        let out = out?;
        ungrab?;
        Ok(out)
    }

    /// The other hosts in [`HOSTS_PROPERTY`] that still run.
    fn live_hosts(&self) -> Res<Vec<u32>> {
        let r = self
            .conn
            .get_property(false, self.root, self.hosts, AtomEnum::CARDINAL, 0, 256)?
            .reply()?;
        let me = std::process::id();
        Ok(r.value32().into_iter().flatten().filter(|&pid| pid != me && host_alive(pid)).collect())
    }

    /// Records the toplevel under the person's pointer and the time on the root window.
    fn note_person(&mut self, master: PersonMaster, always: bool) {
        if !always && self.last_property.is_some_and(|t| t.elapsed() < PROPERTY_EVERY) {
            // Written once more when motion settles (pump).
            self.property_stale = true;
            return;
        }
        self.last_property = Some(Instant::now());
        self.property_stale = false;
        let window = self
            .conn
            .xinput_xi_query_pointer(self.root, master.pointer)
            .ok()
            .and_then(|c| c.reply().ok())
            .map(|r| r.child)
            .unwrap_or(0);
        let held = !self.buttons.is_empty() || self.hold.waiting();
        let body = person_property(master, window, held, unix_ms());
        let _ = self.conn.change_property8(
            PropMode::REPLACE,
            self.root,
            self.property,
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
        self.last_input = Some(Instant::now());
        let Some(master) = self.person() else { return self.send(event, None) };
        let (conn, root) = (&self.conn, self.root);
        let ready =
            self.hold.push(event.clone(), Instant::now(), || Self::agent_holds(conn, root, master));
        for e in &ready {
            self.send(e, Some(master))?;
        }
        if presses(event) && self.hold.waiting() {
            // The agent sees the press the person waits to make.
            self.note_person(master, true);
            self.conn.flush()?;
        }
        Ok(())
    }

    /// Injects queued events whose press the agent no longer blocks (or that waited
    /// [`HOLD_LIMIT`]), writes the property once more after motion settles, and removes
    /// the person master after [`PERSON_IDLE`] with nothing held. Returns when to call
    /// again (None: on the next event).
    pub fn pump(&mut self) -> Res<Option<Duration>> {
        let Person::Attached(master) = self.person else { return Ok(None) };
        if self.hold.waiting() {
            let (conn, root) = (&self.conn, self.root);
            let ready = self.hold.release(Instant::now(), || Self::agent_holds(conn, root, master));
            for e in &ready {
                self.send(e, Some(master))?;
            }
        }
        if self.hold.waiting() {
            return Ok(Some(HOLD_POLL));
        }
        let held = !self.keys.is_empty() || !self.buttons.is_empty();
        let idle = self.last_input.map_or(PERSON_IDLE, |t| t.elapsed());
        if !held && idle >= PERSON_IDLE {
            self.detach();
            return Ok(None);
        }
        if self.property_stale {
            self.note_person(master, false);
            self.conn.flush()?;
        }
        let property = self.property_stale.then(|| {
            let since = self.last_property.map_or(Duration::ZERO, |t| t.elapsed());
            PROPERTY_EVERY.saturating_sub(since).max(Duration::from_millis(1))
        });
        let idle_in = (!held).then(|| PERSON_IDLE - idle);
        Ok(match (property, idle_in) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        })
    }

    fn send(&mut self, event: &InputEvent, person: Option<PersonMaster>) -> Res<()> {
        // Everything but motion writes the property now.
        let mut always = false;
        match event {
            InputEvent::Key { usage, down } => match hid_to_x(*usage) {
                Some(code) => {
                    self.fake(if *down { KEY_PRESS_EVENT } else { KEY_RELEASE_EVENT }, code, 0, 0)?;
                    if *down {
                        self.keys.insert(code);
                    } else {
                        self.keys.remove(&code);
                    }
                    always = true;
                }
                None => self.unsupported += 1,
            },
            InputEvent::Pointer { x, y } => {
                self.fake(MOTION_NOTIFY_EVENT, 0, *x, *y)?;
                self.last_pointer = Some((*x, *y));
            }
            InputEvent::Button { button, down } => {
                let b = (*button).clamp(1, 9);
                self.fake(if *down { BUTTON_PRESS_EVENT } else { BUTTON_RELEASE_EVENT }, b, 0, 0)?;
                if *down {
                    self.buttons.insert(b);
                } else {
                    self.buttons.remove(&b);
                }
                always = true;
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
                always = true;
            }
            // Desktop sessions do not offer the input.service cap.
            InputEvent::Text(_) | InputEvent::Service { .. } => self.unsupported += 1,
        }
        if let Some(m) = person {
            self.note_person(m, always);
        }
        self.conn.flush()?;
        Ok(())
    }

    /// Releases every key and button this injector pressed, drops queued input and lets
    /// go of the person master (with the marker, when no other host uses it). Called when
    /// control ends.
    pub fn release_all(&mut self) -> Res<()> {
        self.hold.clear();
        let released = (|| -> Res<()> {
            for code in std::mem::take(&mut self.keys) {
                self.fake(KEY_RELEASE_EVENT, code, 0, 0)?;
            }
            for b in std::mem::take(&mut self.buttons) {
                self.fake(BUTTON_RELEASE_EVENT, b, 0, 0)?;
            }
            self.conn.flush()?;
            Ok(())
        })();
        self.detach();
        released
    }
}

impl Drop for Injector {
    fn drop(&mut self) {
        let _ = self.release_all();
    }
}

/// Whether `pid` is a running cmux-rd host: alive, with this process's name (a reused pid
/// of something else is not).
fn host_alive(pid: u32) -> bool {
    let comm = |p: &str| std::fs::read(format!("/proc/{p}/comm")).ok();
    matches!((comm(&pid.to_string()), comm("self")), (Some(a), Some(b)) if a == b)
}

fn unix_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// The [`PERSON_PROPERTY`] value. `window` is the root child under the person's pointer
/// (0 when none); `button_held` covers a press waiting behind the agent's button; the host
/// pid lets a reader tell a live host from a crashed one.
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
    let (pointer, _, keyboard, _) = devices.iter().find(|(_, ty, _, n)| {
        *ty == DeviceType::MASTER_POINTER && n.as_slice() == want.as_bytes()
    })?;
    let core = devices
        .iter()
        .find(|(_, ty, _, n)| {
            *ty == DeviceType::MASTER_POINTER && n.as_slice() == b"Virtual core pointer"
        })
        .map_or(0, |(id, ..)| *id);
    devices
        .iter()
        .any(|(id, ty, _, _)| id == keyboard && *ty == DeviceType::MASTER_KEYBOARD)
        .then_some(PersonMaster { pointer: *pointer, keyboard: *keyboard, core })
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
    ) else {
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
        let atom =
            agent.intern_atom(false, PERSON_PROPERTY.as_bytes()).unwrap().reply().unwrap().atom;
        let read = |c: &RustConnection| {
            let r = c
                .get_property(false, root, atom, AtomEnum::STRING, 0, 1024)
                .unwrap()
                .reply()
                .unwrap();
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
    struct Xvfb {
        child: std::process::Child,
        display: String,
    }

    impl Xvfb {
        fn start() -> Self {
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

        fn alive(&mut self) {
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
        assert_eq!(
            core.buttons.first().copied().unwrap_or(0) & 0x3fe,
            0,
            "nor on the core pointer"
        );
        drop(host);
        xvfb.alive();
    }

    /// The person's marker on `root`, if any.
    fn marker(c: &RustConnection, root: Window) -> Option<serde_json::Value> {
        let atom = c.intern_atom(false, PERSON_PROPERTY.as_bytes()).unwrap().reply().unwrap().atom;
        let r =
            c.get_property(false, root, atom, AtomEnum::STRING, 0, 1024).unwrap().reply().unwrap();
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
        let hosts =
            other.intern_atom(false, HOSTS_PROPERTY.as_bytes()).unwrap().reply().unwrap().atom;
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
        let listed = other
            .get_property(false, root, hosts, AtomEnum::CARDINAL, 0, 16)
            .unwrap()
            .reply()
            .unwrap();
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
}
