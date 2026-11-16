//! The portal handshake over real D-Bus: [`ZbusPortal`] against a mock xdg-desktop-portal
//! (ScreenCast, RemoteDesktop, the host Registry and Session objects) on a private bus, a
//! `dbus-daemon` each test starts. The mock behaves as the portal does where it matters
//! here: a restore token is honoured once (Start rotates it), a Start without an honoured
//! token counts as a dialog the person had to answer, and a RemoteDesktop session's sources
//! refuse `persist_mode`.

use super::*;
use std::collections::HashSet;
use std::io::BufRead;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use zbus::zvariant::OwnedObjectPath;

type Opts = HashMap<String, OwnedValue>;

fn opt_u32(o: &Opts, k: &str) -> Option<u32> {
    match o.get(k).map(|v| unwrap_variant(v)) {
        Some(Value::U32(n)) => Some(*n),
        _ => None,
    }
}

fn opt_str(o: &Opts, k: &str) -> Option<String> {
    o.get(k).and_then(|v| value_string(v))
}

#[derive(Clone, Debug, Default)]
struct MockSession {
    remote: bool,
    sources_persist: Option<u32>,
    sources_token: Option<String>,
    devices_persist: Option<u32>,
    devices_token: Option<String>,
}

#[derive(Default)]
struct State {
    rd_version: u32,
    app_ids: Vec<String>,
    /// Starts the person had to answer (no honoured restore token).
    dialogs: u32,
    /// Restore tokens the portal honours (each once).
    valid: HashSet<String>,
    minted: u32,
    sessions: HashMap<String, MockSession>,
    closed: Vec<String>,
    input: Vec<String>,
}

type Shared = Arc<Mutex<State>>;

fn sender_part(hdr: &zbus::message::Header<'_>) -> String {
    hdr.sender().map(|s| s.as_str().trim_start_matches(':').replace('.', "_")).unwrap_or_default()
}

fn fdo(e: impl std::fmt::Display) -> zbus::fdo::Error {
    zbus::fdo::Error::Failed(e.to_string())
}

/// Emits the Request's Response the caller subscribed to, and returns the request handle.
async fn respond(
    conn: &zbus::Connection,
    hdr: &zbus::message::Header<'_>,
    opts: &Opts,
    code: u32,
    results: HashMap<&str, Value<'_>>,
) -> zbus::fdo::Result<OwnedObjectPath> {
    let token = opt_str(opts, "handle_token").unwrap_or_default();
    let path = format!("{PORTAL_PATH}/request/{}/{token}", sender_part(hdr));
    conn.emit_signal(
        None::<&str>,
        path.as_str(),
        "org.freedesktop.portal.Request",
        "Response",
        &(code, results),
    )
    .await
    .map_err(fdo)?;
    OwnedObjectPath::try_from(path).map_err(fdo)
}

async fn create(
    state: &Shared,
    remote: bool,
    opts: &Opts,
    hdr: &zbus::message::Header<'_>,
    conn: &zbus::Connection,
    server: &zbus::ObjectServer,
) -> zbus::fdo::Result<OwnedObjectPath> {
    let token = opt_str(opts, "session_handle_token").unwrap_or_default();
    let session = format!("{PORTAL_PATH}/session/{}/{token}", sender_part(hdr));
    state
        .lock()
        .unwrap()
        .sessions
        .insert(session.clone(), MockSession { remote, ..Default::default() });
    server
        .at(session.as_str(), SessionObject { state: state.clone(), path: session.clone() })
        .await
        .map_err(fdo)?;
    respond(conn, hdr, opts, 0, HashMap::from([("session_handle", Value::from(session))])).await
}

/// Start: honours the offered token once, else counts a dialog; mints a new token when the
/// session asked to persist.
async fn start(
    state: &Shared,
    session: &str,
    opts: &Opts,
    hdr: &zbus::message::Header<'_>,
    conn: &zbus::Connection,
) -> zbus::fdo::Result<OwnedObjectPath> {
    let (remote, token) = {
        let mut st = state.lock().unwrap();
        let rec = st.sessions.get(session).cloned().ok_or_else(|| fdo("no such session"))?;
        let (offered, persist) = if rec.remote {
            (rec.devices_token, rec.devices_persist)
        } else {
            (rec.sources_token, rec.sources_persist)
        };
        let restored = offered.is_some_and(|t| st.valid.remove(&t));
        if !restored {
            st.dialogs += 1;
        }
        let token = (persist == Some(PERSIST_UNTIL_REVOKED)).then(|| {
            st.minted += 1;
            let t = format!("tok-{}", st.minted);
            st.valid.insert(t.clone());
            t
        });
        (rec.remote, token)
    };
    let props: HashMap<String, Value> =
        HashMap::from([("size".to_string(), Value::from((1280i32, 720i32)))]);
    let mut results: HashMap<&str, Value> =
        HashMap::from([("streams", Value::from(vec![(7u32, props)]))]);
    if let Some(t) = token {
        results.insert("restore_token", Value::from(t));
    }
    if remote {
        results.insert("devices", Value::from(DEVICE_KEYBOARD | DEVICE_POINTER));
    }
    respond(conn, hdr, opts, 0, results).await
}

struct ScreenCast {
    state: Shared,
}

#[zbus::interface(name = "org.freedesktop.portal.ScreenCast")]
impl ScreenCast {
    #[zbus(property, name = "version")]
    fn version(&self) -> u32 {
        5
    }

    #[zbus(property)]
    fn available_cursor_modes(&self) -> u32 {
        CURSOR_HIDDEN | CURSOR_EMBEDDED
    }

    async fn create_session(
        &self,
        options: Opts,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
        #[zbus(connection)] conn: &zbus::Connection,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        create(&self.state, false, &options, &hdr, conn, server).await
    }

    async fn select_sources(
        &self,
        session: OwnedObjectPath,
        options: Opts,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
        #[zbus(connection)] conn: &zbus::Connection,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        let refused = {
            let mut st = self.state.lock().unwrap();
            let rec = st.sessions.get_mut(session.as_str()).ok_or_else(|| fdo("no session"))?;
            rec.sources_persist = opt_u32(&options, "persist_mode");
            rec.sources_token = opt_str(&options, "restore_token");
            // The portal: "Remote desktop sessions cannot persist".
            rec.remote && rec.sources_persist.is_some_and(|m| m != PERSIST_NONE)
        };
        respond(conn, &hdr, &options, if refused { 2 } else { 0 }, HashMap::new()).await
    }

    async fn start(
        &self,
        session: OwnedObjectPath,
        _parent_window: String,
        options: Opts,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
        #[zbus(connection)] conn: &zbus::Connection,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        start(&self.state, session.as_str(), &options, &hdr, conn).await
    }

    #[zbus(name = "OpenPipeWireRemote")]
    fn open_pipewire_remote(
        &self,
        _session: OwnedObjectPath,
        _options: Opts,
    ) -> zbus::fdo::Result<zbus::zvariant::OwnedFd> {
        let file = std::fs::File::open("/dev/null").map_err(fdo)?;
        Ok(zbus::zvariant::OwnedFd::from(OwnedFd::from(file)))
    }
}

struct RemoteDesktop {
    state: Shared,
}

#[zbus::interface(name = "org.freedesktop.portal.RemoteDesktop")]
impl RemoteDesktop {
    #[zbus(property, name = "version")]
    fn version(&self) -> u32 {
        self.state.lock().unwrap().rd_version
    }

    async fn create_session(
        &self,
        options: Opts,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
        #[zbus(connection)] conn: &zbus::Connection,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        create(&self.state, true, &options, &hdr, conn, server).await
    }

    async fn select_devices(
        &self,
        session: OwnedObjectPath,
        options: Opts,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
        #[zbus(connection)] conn: &zbus::Connection,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        {
            let mut st = self.state.lock().unwrap();
            let rec = st.sessions.get_mut(session.as_str()).ok_or_else(|| fdo("no session"))?;
            rec.devices_persist = opt_u32(&options, "persist_mode");
            rec.devices_token = opt_str(&options, "restore_token");
        }
        respond(conn, &hdr, &options, 0, HashMap::new()).await
    }

    async fn start(
        &self,
        session: OwnedObjectPath,
        _parent_window: String,
        options: Opts,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
        #[zbus(connection)] conn: &zbus::Connection,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        start(&self.state, session.as_str(), &options, &hdr, conn).await
    }

    fn notify_pointer_motion_absolute(
        &self,
        _session: OwnedObjectPath,
        _options: Opts,
        stream: u32,
        x: f64,
        y: f64,
    ) {
        self.state.lock().unwrap().input.push(format!("motion {stream} {x} {y}"));
    }

    fn notify_pointer_button(
        &self,
        _session: OwnedObjectPath,
        _options: Opts,
        button: i32,
        state: u32,
    ) {
        self.state.lock().unwrap().input.push(format!("button {button} {state}"));
    }

    fn notify_pointer_axis_discrete(
        &self,
        _session: OwnedObjectPath,
        _options: Opts,
        axis: u32,
        steps: i32,
    ) {
        self.state.lock().unwrap().input.push(format!("axis {axis} {steps}"));
    }

    fn notify_keyboard_keycode(
        &self,
        _session: OwnedObjectPath,
        _options: Opts,
        keycode: i32,
        state: u32,
    ) {
        self.state.lock().unwrap().input.push(format!("key {keycode} {state}"));
    }
}

struct Registry {
    state: Shared,
}

#[zbus::interface(name = "org.freedesktop.host.portal.Registry")]
impl Registry {
    fn register(&self, app_id: String, _options: Opts) {
        self.state.lock().unwrap().app_ids.push(app_id);
    }
}

struct SessionObject {
    state: Shared,
    path: String,
}

#[zbus::interface(name = "org.freedesktop.portal.Session")]
impl SessionObject {
    fn close(&self) {
        self.state.lock().unwrap().closed.push(self.path.clone());
    }
}

/// A private bus (our own dbus-daemon, ended on drop) with the mock portal on it.
struct MockPortal {
    daemon: std::process::Child,
    dir: PathBuf,
    address: String,
    state: Shared,
    _server: zbus::blocking::Connection,
}

impl MockPortal {
    fn start(name: &str, rd_version: u32) -> Self {
        let dir = super::tests::temp_dir(name);
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
            .expect("dbus-daemon (package dbus) runs the mock portal's bus");
        let mut address = String::new();
        std::io::BufReader::new(daemon.stdout.take().unwrap()).read_line(&mut address).unwrap();
        let address = address.trim().to_string();
        assert!(!address.is_empty(), "dbus-daemon printed no address");
        let state: Shared = Arc::new(Mutex::new(State { rd_version, ..Default::default() }));
        let server = zbus::blocking::connection::Builder::address(address.as_str())
            .unwrap()
            .serve_at(PORTAL_PATH, ScreenCast { state: state.clone() })
            .unwrap()
            .serve_at(PORTAL_PATH, RemoteDesktop { state: state.clone() })
            .unwrap()
            .serve_at(PORTAL_PATH, Registry { state: state.clone() })
            .unwrap()
            .name(PORTAL_DEST)
            .unwrap()
            .build()
            .unwrap();
        Self { daemon, dir, address, state, _server: server }
    }

    /// A new client connection, as each `cmux-rd serve` or `enable` makes.
    fn client(&self) -> ZbusPortal {
        let conn = zbus::blocking::connection::Builder::address(self.address.as_str())
            .unwrap()
            .build()
            .unwrap();
        ZbusPortal::on(conn).unwrap()
    }

    fn stores(&self) -> TokenStores {
        TokenStores::in_dir(&self.dir.join("config").join("cmux").join("screen-host"))
    }

    fn dialogs(&self) -> u32 {
        self.state.lock().unwrap().dialogs
    }

    /// One share as `serve` opens it: the kind the saved grant allows, the handshake and the
    /// PipeWire remote.
    fn share(&self) -> (ZbusPortal, Started) {
        let mut portal = self.client();
        let stores = self.stores();
        let kind = session_kind(Some(&stores), portal.remote_desktop_version());
        let started = handshake(&mut portal, kind, Some(&stores), &mut |_| {}).unwrap();
        portal.open_pipewire_remote(&started.session).unwrap();
        (portal, started)
    }
}

impl Drop for MockPortal {
    fn drop(&mut self) {
        let _ = self.daemon.kill();
        let _ = self.daemon.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn enable_grants_once_and_every_later_share_starts_without_a_dialog() {
    let mock = MockPortal::start("once", 2);
    let stores = mock.stores();
    let mut portal = mock.client();
    let kind = grant_kind(true, portal.remote_desktop_version());
    assert_eq!(kind, SessionKind::RemoteDesktop);
    let granted = grant_with(&mut portal, kind, &stores, &mut |_| {}).unwrap();
    assert_eq!(granted, Granted { kind: SessionKind::RemoteDesktop, restored: false });
    assert_eq!(mock.dialogs(), 1, "the grant is the one dialog");
    assert!(stores.remote_desktop.load().is_some());
    {
        let st = mock.state.lock().unwrap();
        assert_eq!(st.app_ids, [HOST_APP_ID]);
        assert_eq!(st.closed.len(), 1, "the grant closes its session");
    }
    for _ in 0..3 {
        let before = stores.remote_desktop.load();
        let (_portal, started) = mock.share();
        assert_eq!(started.kind, SessionKind::RemoteDesktop);
        assert!(started.restored);
        assert_eq!(started.devices, DEVICE_KEYBOARD | DEVICE_POINTER);
        assert_eq!(started.stream, PortalStream { node_id: 7, size: Some((1280, 720)) });
        // Each Start rotates the token; the new one is saved for the next share.
        assert_ne!(stores.remote_desktop.load(), before);
    }
    assert_eq!(mock.dialogs(), 1, "no share showed a dialog");
    let st = mock.state.lock().unwrap();
    assert!(st.sessions.values().all(|s| s.remote && s.sources_persist.is_none()));
    assert_eq!(st.app_ids.len(), 4, "every connection registers the same app id");
    assert!(st.app_ids.iter().all(|id| id == HOST_APP_ID));
}

#[test]
fn a_revoked_grant_asks_once_more_then_restores_again() {
    let mock = MockPortal::start("revoked", 2);
    let stores = mock.stores();
    grant_with(&mut mock.client(), SessionKind::RemoteDesktop, &stores, &mut |_| {}).unwrap();
    // The person revoked the permission: the portal honours no saved token.
    mock.state.lock().unwrap().valid.clear();
    let (_p, started) = mock.share();
    assert_eq!(started.kind, SessionKind::RemoteDesktop);
    assert_eq!(mock.dialogs(), 2, "one dialog after the revocation");
    let (_p, started) = mock.share();
    assert!(started.restored);
    assert_eq!(mock.dialogs(), 2, "the new grant restores silently");
}

#[test]
fn a_view_only_desktop_grants_the_screen_cast_alone() {
    let mock = MockPortal::start("view", 2);
    let stores = mock.stores();
    let mut portal = mock.client();
    let kind = grant_kind(false, portal.remote_desktop_version());
    assert_eq!(kind, SessionKind::ScreenCast);
    grant_with(&mut portal, kind, &stores, &mut |_| {}).unwrap();
    assert!(stores.screen_cast.load().is_some());
    assert_eq!(stores.remote_desktop.load(), None);
    let (_p, started) = mock.share();
    assert_eq!(started.kind, SessionKind::ScreenCast);
    assert!(started.restored);
    assert_eq!(mock.dialogs(), 1);
    let st = mock.state.lock().unwrap();
    assert!(st.sessions.values().all(|s| !s.remote && s.sources_persist == Some(2)));
}

#[test]
fn a_portal_that_cannot_keep_a_control_grant_stays_view_only() {
    // RemoteDesktop version 1 cannot persist: asking it would show a dialog on every share.
    let mock = MockPortal::start("rd-v1", 1);
    let mut portal = mock.client();
    assert_eq!(portal.remote_desktop_version(), 1);
    assert_eq!(grant_kind(true, 1), SessionKind::ScreenCast);
    let stores = mock.stores();
    stores.remote_desktop.save("left-over").unwrap();
    assert_eq!(
        session_kind(Some(&stores), portal.remote_desktop_version()),
        SessionKind::ScreenCast
    );
}

#[test]
fn control_input_reaches_the_remote_desktop_session() {
    let mock = MockPortal::start("input", 2);
    grant_with(&mut mock.client(), SessionKind::RemoteDesktop, &mock.stores(), &mut |_| {})
        .unwrap();
    let (portal, started) = mock.share();
    let scale = logical_scale(started.stream.size, (2560, 1440));
    let events = [
        InputEvent::Key { usage: 0x0007_0004, down: true },
        InputEvent::Pointer { x: 200, y: 100 },
        InputEvent::Button { button: 1, down: true },
        InputEvent::Scroll { dx: 0, dy: -300, precise: false },
    ];
    for event in &events {
        for call in input_calls(event, scale) {
            portal.notify(&started.session, started.stream.node_id, &call).unwrap();
        }
    }
    // Motion is sent without a reply: wait for the mock to have seen all four.
    let deadline = Instant::now() + Duration::from_secs(5);
    while mock.state.lock().unwrap().input.len() < 4 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    let mut got = mock.state.lock().unwrap().input.clone();
    got.sort();
    assert_eq!(got, ["axis 0 -3", "button 272 1", "key 30 1", "motion 7 100 50"]);
}
