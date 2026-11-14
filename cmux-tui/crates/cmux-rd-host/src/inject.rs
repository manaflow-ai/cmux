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
    /// Its paired keyboard, whose focus the window manager and apps set (0 when not found).
    core_keyboard: u16,
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

    /// Gives the person's keyboard the focus the core keyboard has. A master keyboard made
    /// with XIChangeHierarchy has a focus of its own, and window managers and apps set only
    /// the core keyboard's (XSetInputFocus), so without this the person's keys reach no
    /// window (CMUX-572: 0 of 20 key presses arrived on an Xvfb desktop).
    fn follow_core_focus(&self, m: PersonMaster) -> Res<()> {
        if m.core_keyboard == 0 {
            return Ok(());
        }
        let focus = self.conn.xinput_xi_get_focus(m.core_keyboard)?.reply()?.focus;
        self.conn.xinput_xi_set_focus(focus, x11rb::CURRENT_TIME, m.keyboard)?;
        Ok(())
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
                    if let (true, Some(m)) = (*down, person) {
                        self.follow_core_focus(m)?;
                    }
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
    let (core, core_keyboard) = devices
        .iter()
        .find(|(_, ty, _, n)| {
            *ty == DeviceType::MASTER_POINTER && n.as_slice() == b"Virtual core pointer"
        })
        .map_or((0, 0), |(id, _, paired, _)| (*id, *paired));
    devices
        .iter()
        .any(|(id, ty, _, _)| id == keyboard && *ty == DeviceType::MASTER_KEYBOARD)
        .then_some(PersonMaster { pointer: *pointer, keyboard: *keyboard, core, core_keyboard })
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
mod tests;
