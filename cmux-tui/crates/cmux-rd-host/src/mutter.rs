//! Wayland screen sharing straight from mutter (GNOME, Linux; feature `portal-dbus`): the
//! compositor's own `org.gnome.Mutter.ScreenCast` and `org.gnome.Mutter.RemoteDesktop`
//! interfaces on the session bus, as gnome-remote-desktop uses them. They hand out the
//! screen and take keyboard and pointer input with no dialog, so a GNOME desktop joined to
//! cmux shares with nobody at its screen to allow it.
//!
//! # Why no dialog
//! xdg-desktop-portal asks the person at the screen because its callers are sandboxed apps.
//! mutter's own interfaces take any caller on the user's session bus (mutter checks only that
//! every later call on a session comes from the connection that created it, and refuses new
//! sessions while remote access is inhibited). The host runs as that user, so it is such a
//! caller. GNOME still shows its screen-sharing indicator in the top bar while a share runs.
//! The interfaces are private to GNOME and promise no compatibility between versions, so
//! only calls present since their first version are used.
//!
//! # How the capture seam picks it
//! A Wayland session's capture (`--capture portal`, `capture_backend.rs`) uses mutter directly
//! when `org.gnome.Mutter.ScreenCast` has an owner on the session bus
//! ([`MutterPresence`], `capture_backend::WaylandCapture`), else the portal as before (KDE and
//! other desktops). `portal::PortalCapture::start` makes the choice; this module is its mutter
//! half, and `linux-host enable` and `grant` ask nothing on such a desktop.
//!
//! # Session
//! With RemoteDesktop present (control): RemoteDesktop.CreateSession, its `SessionId`, then
//! ScreenCast.CreateSession linked to it (`remote-desktop-session-id`), RecordMonitor of the
//! primary monitor (connector `""`, cursor embedded), and Start on the RemoteDesktop session,
//! which starts both. Without it (view only): the ScreenCast session alone, started itself.
//! The stream's `PipeWireStreamAdded` names a node on the session's default PipeWire remote,
//! which `pipewire_capture.rs` streams as it does a portal node. Dropping the session stops
//! it; mutter also ends it when the connection closes.
//!
//! # Input
//! mutter's Notify calls take no session handle or options and a boolean state:
//! NotifyPointerMotionAbsolute (the stream's object path and the position in stream pixels;
//! mutter maps them to the monitor itself, so no logical scale is applied),
//! NotifyPointerButton, NotifyPointerAxisDiscrete and NotifyKeyboardKeycode ([`InputCall`]).

use crate::portal::{InputCall, PortalError};
use std::collections::HashMap;
use std::time::Duration;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

pub const SCREEN_CAST_DEST: &str = "org.gnome.Mutter.ScreenCast";
pub const SCREEN_CAST_PATH: &str = "/org/gnome/Mutter/ScreenCast";
pub const SCREEN_CAST_IFACE: &str = "org.gnome.Mutter.ScreenCast";
pub const SCREEN_CAST_SESSION_IFACE: &str = "org.gnome.Mutter.ScreenCast.Session";
pub const SCREEN_CAST_STREAM_IFACE: &str = "org.gnome.Mutter.ScreenCast.Stream";
pub const REMOTE_DESKTOP_DEST: &str = "org.gnome.Mutter.RemoteDesktop";
pub const REMOTE_DESKTOP_PATH: &str = "/org/gnome/Mutter/RemoteDesktop";
pub const REMOTE_DESKTOP_IFACE: &str = "org.gnome.Mutter.RemoteDesktop";
pub const REMOTE_DESKTOP_SESSION_IFACE: &str = "org.gnome.Mutter.RemoteDesktop.Session";

/// RecordMonitor `cursor-mode` (mutter's values, not the portal's bits): drawn in the picture.
pub const CURSOR_MODE_EMBEDDED: u32 = 1;
/// RecordMonitor connector naming the primary monitor.
pub const PRIMARY_MONITOR: &str = "";

/// Which of mutter's interfaces have an owner on the session bus.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MutterPresence {
    pub screen_cast: bool,
    pub remote_desktop: bool,
}

impl MutterPresence {
    /// Asks the bus `conn` is on (`NameHasOwner`; nothing of mutter's is called).
    pub fn on(conn: &zbus::blocking::Connection) -> Self {
        let has_owner = |name: &str| {
            conn.call_method(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                Some("org.freedesktop.DBus"),
                "NameHasOwner",
                &(name,),
            )
            .ok()
            .and_then(|m| m.body().deserialize::<bool>().ok())
            .unwrap_or(false)
        };
        Self {
            screen_cast: has_owner(SCREEN_CAST_DEST),
            remote_desktop: has_owner(REMOTE_DESKTOP_DEST),
        }
    }

    /// [`MutterPresence::on`] the session bus; none when there is no session bus.
    pub fn detect() -> Self {
        zbus::blocking::Connection::session().map(|c| Self::on(&c)).unwrap_or_default()
    }
}

fn failed(e: impl std::fmt::Display) -> PortalError {
    PortalError::Failed(e.to_string())
}

fn proxy(
    conn: &zbus::blocking::Connection,
    dest: &'static str,
    path: impl Into<String>,
    iface: &'static str,
) -> Result<zbus::blocking::Proxy<'static>, PortalError> {
    zbus::blocking::Proxy::new(conn, dest, path.into(), iface).map_err(failed)
}

/// A started mutter screen cast (with its RemoteDesktop session when mutter has one). Keep
/// it alive while streaming: dropping it stops the session.
pub struct MutterSession {
    conn: zbus::blocking::Connection,
    remote_desktop: Option<zbus::blocking::Proxy<'static>>,
    screen_cast: zbus::blocking::Proxy<'static>,
    /// The stream's object path (NotifyPointerMotionAbsolute names it).
    stream: String,
    /// The stream's node on the session's default PipeWire remote.
    pub node_id: u32,
    /// The monitor's size from the stream's `Parameters`, when mutter gave it.
    pub size: Option<(i32, i32)>,
}

impl MutterSession {
    /// Creates, records the primary monitor and starts a session on `conn` (the session bus;
    /// tests pass a private bus with a mock mutter), waiting up to `timeout` for the stream's
    /// PipeWire node. A RemoteDesktop session (input) is made when `presence` has one.
    pub fn start(
        conn: zbus::blocking::Connection,
        presence: MutterPresence,
        timeout: Duration,
    ) -> Result<Self, PortalError> {
        let unavailable = |e: zbus::Error| PortalError::Unavailable(e.to_string());
        let mut sc_props: HashMap<&str, Value> = HashMap::new();
        let remote_desktop = if presence.remote_desktop {
            let rd = proxy(&conn, REMOTE_DESKTOP_DEST, REMOTE_DESKTOP_PATH, REMOTE_DESKTOP_IFACE)?;
            let path: OwnedObjectPath = rd.call("CreateSession", &()).map_err(unavailable)?;
            let session =
                proxy(&conn, REMOTE_DESKTOP_DEST, path.as_str(), REMOTE_DESKTOP_SESSION_IFACE)?;
            let id: String = session.get_property("SessionId").map_err(failed)?;
            sc_props.insert("remote-desktop-session-id", Value::from(id));
            Some(session)
        } else {
            None
        };
        let sc = proxy(&conn, SCREEN_CAST_DEST, SCREEN_CAST_PATH, SCREEN_CAST_IFACE)?;
        let path: OwnedObjectPath = sc.call("CreateSession", &(sc_props,)).map_err(unavailable)?;
        let screen_cast = proxy(&conn, SCREEN_CAST_DEST, path.as_str(), SCREEN_CAST_SESSION_IFACE)?;
        // From here on the sessions exist: Drop stops them on any failure below.
        let mut me = Self {
            conn,
            remote_desktop,
            screen_cast,
            stream: String::new(),
            node_id: 0,
            size: None,
        };
        let record: HashMap<&str, Value> =
            HashMap::from([("cursor-mode", Value::from(CURSOR_MODE_EMBEDDED))]);
        let stream_path: OwnedObjectPath =
            me.screen_cast.call("RecordMonitor", &(PRIMARY_MONITOR, record)).map_err(failed)?;
        me.stream = stream_path.to_string();
        let stream =
            proxy(&me.conn, SCREEN_CAST_DEST, me.stream.clone(), SCREEN_CAST_STREAM_IFACE)?;
        // Subscribed before Start, so the node mutter announces at Start is not missed. The
        // version 1 signal: mutter still sends it beside PipeWireStreamAddedV2.
        let mut added = stream.receive_signal("PipeWireStreamAdded").map_err(failed)?;
        // A linked screen cast is started by its RemoteDesktop session.
        me.starter().call_method("Start", &()).map_err(failed)?;
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::Builder::new()
            .name("cmux-rd-mutter-node".into())
            .spawn(move || {
                let node = added.next().and_then(|m| m.body().deserialize::<u32>().ok());
                let _ = tx.send(node);
            })
            .map_err(failed)?;
        me.node_id = match rx.recv_timeout(timeout) {
            Ok(Some(node)) => node,
            Ok(None) => return Err(failed("mutter's screen cast stream sent no PipeWire node")),
            Err(_) => {
                return Err(failed(format!(
                    "mutter's screen cast stream named no PipeWire node within {} s",
                    timeout.as_secs()
                )))
            }
        };
        me.size = stream
            .get_property::<HashMap<String, OwnedValue>>("Parameters")
            .ok()
            .and_then(|p| p.get("size").and_then(|v| <(i32, i32)>::try_from(v.clone()).ok()));
        Ok(me)
    }

    /// The session Start and Stop go to: the RemoteDesktop one when linked.
    fn starter(&self) -> &zbus::blocking::Proxy<'static> {
        self.remote_desktop.as_ref().unwrap_or(&self.screen_cast)
    }

    /// Whether the session applies input (mutter has RemoteDesktop).
    pub fn applies_input(&self) -> bool {
        self.remote_desktop.is_some()
    }

    /// Sends one Notify call. Motion is sent without waiting for a reply (the next one
    /// supersedes it); the rest wait, so an error is seen.
    pub fn notify(&self, call: &InputCall) -> Result<(), PortalError> {
        let rd = self
            .remote_desktop
            .as_ref()
            .ok_or_else(|| failed("this mutter screen cast has no RemoteDesktop session"))?;
        match *call {
            InputCall::Motion { x, y } => rd
                .call_noreply("NotifyPointerMotionAbsolute", &(self.stream.as_str(), x, y))
                .map_err(failed),
            InputCall::Button { code, down } => {
                rd.call_method("NotifyPointerButton", &(code, down)).map(drop).map_err(failed)
            }
            InputCall::Axis { axis, steps } => rd
                .call_method("NotifyPointerAxisDiscrete", &(axis, steps))
                .map(drop)
                .map_err(failed),
            InputCall::Key { code, down } => {
                let code = u32::try_from(code).map_err(failed)?;
                rd.call_method("NotifyKeyboardKeycode", &(code, down)).map(drop).map_err(failed)
            }
        }
    }
}

impl Drop for MutterSession {
    fn drop(&mut self) {
        // A session that never started refuses Stop; mutter drops it with the connection.
        let _ = self.starter().call_method("Stop", &());
    }
}

#[cfg(test)]
#[path = "mutter_mock_bus_tests.rs"]
mod mock_bus_tests;
