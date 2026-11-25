//! mutter's screen cast over real D-Bus: [`MutterSession`] against a mock mutter
//! (`org.gnome.Mutter.ScreenCast` and `org.gnome.Mutter.RemoteDesktop`, their Session and
//! Stream objects) on a private bus, a `dbus-daemon` each test starts. The mock behaves as
//! mutter does where it matters here: only the connection that created a session may call it,
//! a screen cast linked to a RemoteDesktop session is started by that session alone, Start
//! announces the stream's PipeWire node, and no call shows anything to anyone.

use super::*;
use std::io::BufRead;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Instant;

type Opts = HashMap<String, OwnedValue>;

#[derive(Default)]
struct State {
    /// Every call in order, as "Iface.Method" words.
    calls: Vec<String>,
    /// The unique name that created the sessions (mutter's same-peer rule).
    creator: Option<String>,
    /// The ScreenCast session's `remote-desktop-session-id`, when linked.
    linked: Option<String>,
    cursor_mode: Option<u32>,
    connector: Option<String>,
    input: Vec<String>,
}

type Shared = Arc<Mutex<State>>;

const RD_SESSION: &str = "/org/gnome/Mutter/RemoteDesktop/Session/u1";
const SC_SESSION: &str = "/org/gnome/Mutter/ScreenCast/Session/u1";
const STREAM: &str = "/org/gnome/Mutter/ScreenCast/Stream/u1";

fn fdo(e: impl std::fmt::Display) -> zbus::fdo::Error {
    zbus::fdo::Error::Failed(e.to_string())
}

fn sender(hdr: &zbus::message::Header<'_>) -> String {
    hdr.sender().map(|s| s.to_string()).unwrap_or_default()
}

/// mutter's `check_permission`: a session answers only the peer that created it.
fn same_peer(state: &Shared, hdr: &zbus::message::Header<'_>) -> zbus::fdo::Result<()> {
    if state.lock().unwrap().creator.as_deref() == Some(sender(hdr).as_str()) {
        Ok(())
    } else {
        Err(zbus::fdo::Error::AccessDenied("Permission denied".into()))
    }
}

fn call(state: &Shared, what: &str) {
    state.lock().unwrap().calls.push(what.into());
}

async fn announce_node(conn: &zbus::Connection) -> zbus::fdo::Result<()> {
    conn.emit_signal(
        None::<&str>,
        STREAM,
        SCREEN_CAST_STREAM_IFACE,
        "PipeWireStreamAdded",
        &(7u32,),
    )
    .await
    .map_err(fdo)
}

struct ScreenCast {
    state: Shared,
}

#[zbus::interface(name = "org.gnome.Mutter.ScreenCast")]
impl ScreenCast {
    #[zbus(property)]
    fn version(&self) -> i32 {
        4
    }

    async fn create_session(
        &self,
        properties: Opts,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        {
            let mut st = self.state.lock().unwrap();
            st.calls.push("ScreenCast.CreateSession".into());
            st.creator.get_or_insert_with(|| sender(&hdr));
            st.linked = properties
                .get("remote-desktop-session-id")
                .and_then(|v| String::try_from(v.try_clone().ok()?).ok());
        }
        server
            .at(SC_SESSION, ScreenCastSession { state: self.state.clone() })
            .await
            .map_err(fdo)?;
        OwnedObjectPath::try_from(SC_SESSION).map_err(fdo)
    }
}

struct ScreenCastSession {
    state: Shared,
}

#[zbus::interface(name = "org.gnome.Mutter.ScreenCast.Session")]
impl ScreenCastSession {
    async fn record_monitor(
        &self,
        connector: String,
        properties: Opts,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        same_peer(&self.state, &hdr)?;
        {
            let mut st = self.state.lock().unwrap();
            st.calls.push("ScreenCast.Session.RecordMonitor".into());
            st.connector = Some(connector);
            st.cursor_mode =
                properties.get("cursor-mode").and_then(|v| u32::try_from(v.try_clone().ok()?).ok());
        }
        server.at(STREAM, Stream).await.map_err(fdo)?;
        OwnedObjectPath::try_from(STREAM).map_err(fdo)
    }

    async fn start(
        &self,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
        #[zbus(connection)] conn: &zbus::Connection,
    ) -> zbus::fdo::Result<()> {
        same_peer(&self.state, &hdr)?;
        if self.state.lock().unwrap().linked.is_some() {
            return Err(fdo("Must be started from remote desktop session"));
        }
        call(&self.state, "ScreenCast.Session.Start");
        announce_node(conn).await
    }

    fn stop(&self, #[zbus(header)] hdr: zbus::message::Header<'_>) -> zbus::fdo::Result<()> {
        same_peer(&self.state, &hdr)?;
        call(&self.state, "ScreenCast.Session.Stop");
        Ok(())
    }
}

struct Stream;

#[zbus::interface(name = "org.gnome.Mutter.ScreenCast.Stream")]
impl Stream {
    #[zbus(property)]
    fn parameters(&self) -> HashMap<String, OwnedValue> {
        let v = |v: Value<'_>| OwnedValue::try_from(v).unwrap();
        HashMap::from([
            ("position".to_string(), v(Value::from((0i32, 0i32)))),
            ("size".to_string(), v(Value::from((1920i32, 1080i32)))),
        ])
    }
}

struct RemoteDesktop {
    state: Shared,
}

#[zbus::interface(name = "org.gnome.Mutter.RemoteDesktop")]
impl RemoteDesktop {
    #[zbus(property)]
    fn supported_device_types(&self) -> u32 {
        3
    }

    async fn create_session(
        &self,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        {
            let mut st = self.state.lock().unwrap();
            st.calls.push("RemoteDesktop.CreateSession".into());
            st.creator = Some(sender(&hdr));
        }
        server
            .at(RD_SESSION, RemoteDesktopSession { state: self.state.clone() })
            .await
            .map_err(fdo)?;
        OwnedObjectPath::try_from(RD_SESSION).map_err(fdo)
    }
}

struct RemoteDesktopSession {
    state: Shared,
}

#[zbus::interface(name = "org.gnome.Mutter.RemoteDesktop.Session")]
impl RemoteDesktopSession {
    #[zbus(property)]
    fn session_id(&self) -> String {
        "rd-session-1".into()
    }

    async fn start(
        &self,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
        #[zbus(connection)] conn: &zbus::Connection,
    ) -> zbus::fdo::Result<()> {
        same_peer(&self.state, &hdr)?;
        call(&self.state, "RemoteDesktop.Session.Start");
        announce_node(conn).await
    }

    fn stop(&self, #[zbus(header)] hdr: zbus::message::Header<'_>) -> zbus::fdo::Result<()> {
        same_peer(&self.state, &hdr)?;
        call(&self.state, "RemoteDesktop.Session.Stop");
        Ok(())
    }

    fn notify_pointer_motion_absolute(
        &self,
        stream: String,
        x: f64,
        y: f64,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
    ) -> zbus::fdo::Result<()> {
        same_peer(&self.state, &hdr)?;
        self.state.lock().unwrap().input.push(format!("motion {stream} {x} {y}"));
        Ok(())
    }

    fn notify_pointer_button(
        &self,
        button: i32,
        state: bool,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
    ) -> zbus::fdo::Result<()> {
        same_peer(&self.state, &hdr)?;
        self.state.lock().unwrap().input.push(format!("button {button} {state}"));
        Ok(())
    }

    fn notify_pointer_axis_discrete(
        &self,
        axis: u32,
        steps: i32,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
    ) -> zbus::fdo::Result<()> {
        same_peer(&self.state, &hdr)?;
        self.state.lock().unwrap().input.push(format!("axis {axis} {steps}"));
        Ok(())
    }

    fn notify_keyboard_keycode(
        &self,
        keycode: u32,
        state: bool,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
    ) -> zbus::fdo::Result<()> {
        same_peer(&self.state, &hdr)?;
        self.state.lock().unwrap().input.push(format!("key {keycode} {state}"));
        Ok(())
    }
}

/// A private bus (our own dbus-daemon, ended on drop) with the mock mutter on it.
struct MockMutter {
    daemon: std::process::Child,
    dir: PathBuf,
    address: String,
    state: Shared,
    _server: zbus::blocking::Connection,
}

impl MockMutter {
    /// `remote_desktop`: whether mutter offers RemoteDesktop beside ScreenCast.
    fn start(name: &str, remote_desktop: bool) -> Self {
        let dir =
            std::env::temp_dir().join(format!("cmux-rd-mutter-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("bus.conf");
        std::fs::write(
            &config,
            format!(
                r#"<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path={}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
"#,
                dir.join("bus").display()
            ),
        )
        .unwrap();
        let mut daemon = std::process::Command::new("dbus-daemon")
            .arg(format!("--config-file={}", config.display()))
            .args(["--nofork", "--nopidfile", "--print-address=1"])
            .stdout(std::process::Stdio::piped())
            .spawn()
            .expect("dbus-daemon (package dbus) runs the mock mutter's bus");
        let mut address = String::new();
        std::io::BufReader::new(daemon.stdout.take().unwrap()).read_line(&mut address).unwrap();
        let address = address.trim().to_string();
        assert!(!address.is_empty(), "dbus-daemon printed no address");
        let state: Shared = Arc::default();
        let mut server = zbus::blocking::connection::Builder::address(address.as_str())
            .unwrap()
            .serve_at(SCREEN_CAST_PATH, ScreenCast { state: state.clone() })
            .unwrap()
            .name(SCREEN_CAST_DEST)
            .unwrap();
        if remote_desktop {
            server = server
                .serve_at(REMOTE_DESKTOP_PATH, RemoteDesktop { state: state.clone() })
                .unwrap()
                .name(REMOTE_DESKTOP_DEST)
                .unwrap();
        }
        let server = server.build().unwrap();
        Self { daemon, dir, address, state, _server: server }
    }

    /// A new client connection, as each `cmux-rd serve` makes.
    fn client(&self) -> zbus::blocking::Connection {
        zbus::blocking::connection::Builder::address(self.address.as_str())
            .unwrap()
            .build()
            .unwrap()
    }

    fn share(&self) -> MutterSession {
        let conn = self.client();
        let presence = MutterPresence::on(&conn);
        MutterSession::start(conn, presence, Duration::from_secs(5)).unwrap()
    }

    fn calls(&self) -> Vec<String> {
        self.state.lock().unwrap().calls.clone()
    }
}

impl Drop for MockMutter {
    fn drop(&mut self) {
        let _ = self.daemon.kill();
        let _ = self.daemon.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn presence_reads_which_mutter_interfaces_own_their_names() {
    let gnome = MockMutter::start("presence", true);
    assert_eq!(
        MutterPresence::on(&gnome.client()),
        MutterPresence { screen_cast: true, remote_desktop: true }
    );
    let view = MockMutter::start("presence-view", false);
    assert_eq!(
        MutterPresence::on(&view.client()),
        MutterPresence { screen_cast: true, remote_desktop: false }
    );
    assert!(gnome.calls().is_empty() && view.calls().is_empty(), "detection calls no mutter");
}

#[test]
fn a_gnome_share_starts_through_mutter_with_no_grant_and_stops_on_drop() {
    let mock = MockMutter::start("share", true);
    let session = mock.share();
    assert_eq!(session.node_id, 7);
    assert_eq!(session.size, Some((1920, 1080)));
    assert!(session.applies_input());
    assert_eq!(
        mock.calls(),
        [
            "RemoteDesktop.CreateSession",
            "ScreenCast.CreateSession",
            "ScreenCast.Session.RecordMonitor",
            "RemoteDesktop.Session.Start",
        ]
    );
    {
        let st = mock.state.lock().unwrap();
        assert_eq!(st.linked.as_deref(), Some("rd-session-1"));
        assert_eq!(st.connector.as_deref(), Some(PRIMARY_MONITOR));
        assert_eq!(st.cursor_mode, Some(CURSOR_MODE_EMBEDDED));
    }
    drop(session);
    assert_eq!(mock.calls().last().map(String::as_str), Some("RemoteDesktop.Session.Stop"));
}

#[test]
fn every_share_starts_the_same_way_with_nothing_saved() {
    let mock = MockMutter::start("again", true);
    for _ in 0..3 {
        let session = mock.share();
        assert_eq!(session.node_id, 7);
    }
    let starts = mock.calls().iter().filter(|c| *c == "RemoteDesktop.Session.Start").count();
    let stops = mock.calls().iter().filter(|c| *c == "RemoteDesktop.Session.Stop").count();
    assert_eq!((starts, stops), (3, 3));
}

#[test]
fn a_mutter_without_remote_desktop_casts_view_only() {
    let mock = MockMutter::start("view-only", false);
    let session = mock.share();
    assert_eq!(session.node_id, 7);
    assert!(!session.applies_input());
    assert!(session.notify(&InputCall::Key { code: 30, down: true }).is_err());
    assert_eq!(mock.state.lock().unwrap().linked, None);
    drop(session);
    assert_eq!(
        mock.calls(),
        [
            "ScreenCast.CreateSession",
            "ScreenCast.Session.RecordMonitor",
            "ScreenCast.Session.Start",
            "ScreenCast.Session.Stop",
        ]
    );
}

#[test]
fn control_input_reaches_mutter_in_stream_pixels() {
    let mock = MockMutter::start("input", true);
    let session = mock.share();
    let events = [
        cmux_rd_proto::InputEvent::Key { usage: 0x0007_0004, down: true },
        cmux_rd_proto::InputEvent::Pointer { x: 200, y: 100 },
        cmux_rd_proto::InputEvent::Button { button: 1, down: true },
        cmux_rd_proto::InputEvent::Scroll { dx: 0, dy: -300, precise: false },
    ];
    // mutter maps stream pixels to the monitor itself: no logical scale.
    for event in &events {
        for call in crate::portal::input_calls(event, (1.0, 1.0)) {
            session.notify(&call).unwrap();
        }
    }
    // Motion is sent without a reply: wait for the mock to have seen all four.
    let deadline = Instant::now() + Duration::from_secs(5);
    while mock.state.lock().unwrap().input.len() < 4 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    let mut got = mock.state.lock().unwrap().input.clone();
    got.sort();
    assert_eq!(
        got,
        ["axis 0 -3", "button 272 true", "key 30 true", &format!("motion {STREAM} 200 100")]
    );
}

#[test]
fn another_connection_cannot_drive_the_session() {
    // mutter's only check on these calls: the peer that created the session.
    let mock = MockMutter::start("peer", true);
    let _session = mock.share();
    let other = mock.client();
    let refused = other.call_method(
        Some(REMOTE_DESKTOP_DEST),
        RD_SESSION,
        Some(REMOTE_DESKTOP_SESSION_IFACE),
        "NotifyKeyboardKeycode",
        &(30u32, true),
    );
    assert!(refused.is_err());
    assert!(mock.state.lock().unwrap().input.is_empty());
}
