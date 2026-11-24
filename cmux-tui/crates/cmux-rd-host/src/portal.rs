//! Wayland screen sharing through xdg-desktop-portal (Linux): the ScreenCast and RemoteDesktop
//! handshakes over D-Bus (feature `portal-dbus`), then the PipeWire stream they open
//! (feature `portal`, src/pipewire_capture.rs). It lets a viewer watch, and with a
//! RemoteDesktop grant control, a Wayland desktop (a GNOME-style seat0 session with no X
//! server).
//!
//! # How serve plugs it in
//! [`PortalCapture::start`] is the one constructor. It returns a capturer with the same
//! surface as `capture::Capturer` on X11: `width`/`height`, [`PortalCapture::fd`] (readable
//! when damage waits), [`PortalCapture::drain`] (damage as `capture::DamageEvent`) and
//! [`PortalCapture::frames`] (a reader of the newest picture for the encode thread, a
//! rectangle as BGRX rows of stride `w * 4`). [`open_desktop`] wraps it as the session's
//! `desktop::Desktop` and `desktop::FrameSource` halves with the session's encoder, chosen by
//! the capture-backend seam (`--capture portal|x11`) in desktop.rs.
//!
//! # Handshake
//! A ScreenCast session: CreateSession, SelectSources (one monitor, cursor embedded where
//! offered, else as metadata, `persist_mode` 2 with the saved `restore_token`), Start,
//! OpenPipeWireRemote. A RemoteDesktop session (control): RemoteDesktop.CreateSession,
//! SelectDevices (keyboard and pointer, `persist_mode` 2 with its saved token), ScreenCast
//! SelectSources on the same session (no persistence of its own), RemoteDesktop.Start,
//! OpenPipeWireRemote. Each Start returns a new restore token; it is saved in
//! `~/.config/cmux/screen-host/` ([`TokenStores`]), so the person at the screen allows
//! sharing once and later sessions start with no dialog. A token the portal no longer honours
//! (the person revoked it) makes the portal show its dialog once; the new token is saved.
//!
//! # The grant is made once, at enable
//! `cmux-rd linux-host enable` (and `linux-host grant`) runs [`grant`]: the same handshake
//! with no PipeWire stream, which shows the portal's dialog while the person who is joining
//! the desktop is at it, saves the token and closes the session. No share asks again.
//! Both the grant and every session register one host app id with the portal's Registry
//! (where the portal has it), so a token granted from a terminal restores in the user unit.
//!
//! # Input
//! With a RemoteDesktop grant saved, sessions are RemoteDesktop sessions and a control
//! session's input goes through NotifyPointerMotionAbsolute, NotifyPointerButton,
//! NotifyPointerAxisDiscrete and NotifyKeyboardKeycode ([`input_calls`]). RemoteDesktop
//! version 1 cannot persist a grant, so it is not used (it would ask on every share): such a
//! desktop is served view only.

#[cfg(feature = "portal")]
use crate::capture::{DamageEvent, Rect};
#[cfg(feature = "portal")]
use crate::pipewire_capture::PwStream;
#[cfg(feature = "portal")]
use crate::Res;
use cmux_rd_proto::InputEvent;
use std::collections::HashMap;
use std::os::fd::OwnedFd;
#[cfg(feature = "portal")]
use std::os::fd::RawFd;
use std::path::{Path, PathBuf};
#[cfg(feature = "portal")]
use std::time::Duration;
use zbus::zvariant::{ObjectPath, OwnedValue, Value};

/// SelectSources `types`: a monitor.
pub const SOURCE_MONITOR: u32 = 1;
/// `cursor_mode` bits (AvailableCursorModes).
pub const CURSOR_HIDDEN: u32 = 1;
pub const CURSOR_EMBEDDED: u32 = 2;
pub const CURSOR_METADATA: u32 = 4;
/// `persist_mode`: not persisted (a RemoteDesktop session's sources persist with its devices).
pub const PERSIST_NONE: u32 = 0;
/// `persist_mode`: until the person revokes it.
pub const PERSIST_UNTIL_REVOKED: u32 = 2;
/// SelectDevices `types` bits.
pub const DEVICE_KEYBOARD: u32 = 1;
pub const DEVICE_POINTER: u32 = 2;
/// The first RemoteDesktop version whose SelectDevices takes `persist_mode` and
/// `restore_token`.
pub const REMOTE_DESKTOP_PERSISTS: u32 = 2;
/// The app id the grant and every session register with the portal's host Registry.
pub const HOST_APP_ID: &str = "com.cmuxterm.ScreenHost";

/// Which portal session shares the screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionKind {
    /// ScreenCast alone: the viewer watches.
    ScreenCast,
    /// RemoteDesktop with its screen cast: the viewer can also control.
    RemoteDesktop,
}

/// Where the handshake is, for the app to show.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PortalState {
    /// Opening the session bus and the portal.
    Connecting,
    CreatingSession,
    /// Starting with a saved restore token: no dialog expected.
    Restoring,
    /// The portal's dialog is up on the seat; nothing streams until someone answers it.
    WaitingForConsent,
    /// The PipeWire stream negotiated its first picture.
    Streaming {
        width: u32,
        height: u32,
    },
}

impl PortalState {
    pub fn message(&self) -> String {
        match self {
            Self::Connecting => "connecting to the screen cast portal".into(),
            Self::CreatingSession => "creating a screen cast session".into(),
            Self::Restoring => {
                "restoring the screen the person at the screen allowed before".into()
            }
            Self::WaitingForConsent => {
                "waiting for the person at the screen to allow sharing".into()
            }
            Self::Streaming { width, height } => format!("streaming the screen ({width}x{height})"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PortalError {
    /// The person at the screen declined (or closed) the sharing dialog.
    Cancelled,
    /// No session bus or no ScreenCast portal.
    Unavailable(String),
    Failed(String),
}

impl std::fmt::Display for PortalError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Cancelled => write!(f, "the person at the screen did not allow sharing"),
            Self::Unavailable(e) => write!(f, "screen cast portal unavailable: {e}"),
            Self::Failed(e) => write!(f, "screen cast portal: {e}"),
        }
    }
}

impl std::error::Error for PortalError {}

/// Maps a portal Request's Response code: 0 success, 1 cancelled by the person, 2 other.
pub fn response_result<T>(code: u32, results: T) -> Result<T, PortalError> {
    match code {
        0 => Ok(results),
        1 => Err(PortalError::Cancelled),
        n => Err(PortalError::Failed(format!("request ended with response {n}"))),
    }
}

/// SelectSources options.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SourceSelection {
    pub types: u32,
    pub multiple: bool,
    pub cursor_mode: Option<u32>,
    pub persist_mode: u32,
    pub restore_token: Option<String>,
}

/// SelectDevices options (RemoteDesktop).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceSelection {
    pub types: u32,
    pub persist_mode: u32,
    pub restore_token: Option<String>,
}

/// One stream of a Start response.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PortalStream {
    pub node_id: u32,
    /// The stream's size in the compositor's logical pixels, the space pointer motion uses.
    pub size: Option<(i32, i32)>,
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct StartResult {
    pub streams: Vec<PortalStream>,
    pub restore_token: Option<String>,
    /// The RemoteDesktop devices granted (`DEVICE_*` bits); 0 for a ScreenCast session.
    pub devices: u32,
}

/// The portal calls the handshake makes. [`ZbusPortal`] talks to the real portal over the
/// session bus; tests drive the handshake with a fake, and the D-Bus test with a mock portal
/// on a private bus.
pub trait DesktopPortal {
    /// The AvailableCursorModes bits (0 when the portal predates cursor modes).
    fn available_cursor_modes(&mut self) -> u32;
    /// The RemoteDesktop interface version, 0 when the portal has none.
    fn remote_desktop_version(&mut self) -> u32;
    /// Returns the session handle.
    fn create_session(&mut self, kind: SessionKind) -> Result<String, PortalError>;
    fn select_devices(&mut self, session: &str, sel: &DeviceSelection) -> Result<(), PortalError>;
    fn select_sources(&mut self, session: &str, sel: &SourceSelection) -> Result<(), PortalError>;
    /// Blocks until the portal answers (with a dialog, until the person does).
    fn start(&mut self, kind: SessionKind, session: &str) -> Result<StartResult, PortalError>;
    fn open_pipewire_remote(&mut self, session: &str) -> Result<OwnedFd, PortalError>;
    fn close_session(&mut self, session: &str);
}

/// Saves one portal restore token as a 0600 file.
#[derive(Clone, Debug)]
pub struct RestoreTokenStore {
    path: PathBuf,
    /// An older location read when `path` has no token, and removed once `path` has one.
    legacy: Option<PathBuf>,
}

impl RestoreTokenStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path, legacy: None }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn read(path: &Path) -> Option<String> {
        let s = std::fs::read_to_string(path).ok()?;
        let t = s.trim();
        (!t.is_empty()).then(|| t.to_string())
    }

    pub fn load(&self) -> Option<String> {
        Self::read(&self.path).or_else(|| self.legacy.as_deref().and_then(Self::read))
    }

    /// Writes the token atomically (a temporary file renamed over the old one).
    pub fn save(&self, token: &str) -> std::io::Result<()> {
        use std::io::Write;
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
        }
        let tmp = self.path.with_extension(format!("tmp{}", std::process::id()));
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(token.as_bytes())?;
        f.sync_all()?;
        std::fs::rename(&tmp, &self.path)?;
        if let Some(old) = &self.legacy {
            let _ = std::fs::remove_file(old);
        }
        Ok(())
    }

    pub fn clear(&self) {
        let _ = std::fs::remove_file(&self.path);
        if let Some(old) = &self.legacy {
            let _ = std::fs::remove_file(old);
        }
    }
}

/// The restore tokens of both session kinds, in the screen host's directory.
#[derive(Clone, Debug)]
pub struct TokenStores {
    pub screen_cast: RestoreTokenStore,
    pub remote_desktop: RestoreTokenStore,
}

impl TokenStores {
    /// The stores in `dir`: `portal-screencast.token` and `portal-remote-desktop.token`.
    pub fn in_dir(dir: &Path) -> Self {
        Self {
            screen_cast: RestoreTokenStore::new(dir.join("portal-screencast.token")),
            remote_desktop: RestoreTokenStore::new(dir.join("portal-remote-desktop.token")),
        }
    }

    /// `$XDG_CONFIG_HOME/cmux/screen-host/` (else `~/.config/...`), the screen host's own
    /// directory; the ScreenCast store also reads the token earlier builds saved in
    /// `cmux/rd-portal-restore-token`. `None` with neither variable set.
    pub fn default_stores() -> Option<Self> {
        let abs = |k: &str| std::env::var_os(k).map(PathBuf::from).filter(|p| p.is_absolute());
        let cmux =
            abs("XDG_CONFIG_HOME").or_else(|| Some(abs("HOME")?.join(".config")))?.join("cmux");
        let mut stores = Self::in_dir(&cmux.join("screen-host"));
        stores.screen_cast.legacy = Some(cmux.join("rd-portal-restore-token"));
        Some(stores)
    }

    pub fn for_kind(&self, kind: SessionKind) -> &RestoreTokenStore {
        match kind {
            SessionKind::ScreenCast => &self.screen_cast,
            SessionKind::RemoteDesktop => &self.remote_desktop,
        }
    }
}

/// Whether a RemoteDesktop grant is saved, so portal sessions can apply a viewer's input.
pub fn remote_desktop_granted() -> bool {
    TokenStores::default_stores().is_some_and(|s| s.remote_desktop.load().is_some())
}

/// Whether any portal grant is saved, so a session starts with no dialog.
pub fn any_grant_saved() -> bool {
    TokenStores::default_stores()
        .is_some_and(|s| s.remote_desktop.load().is_some() || s.screen_cast.load().is_some())
}

/// The session kind a share uses: RemoteDesktop when its grant is saved and the portal can
/// persist it (so control needs no dialog), else ScreenCast.
pub fn session_kind(stores: Option<&TokenStores>, remote_desktop_version: u32) -> SessionKind {
    let granted = stores.is_some_and(|s| s.remote_desktop.load().is_some());
    if granted && remote_desktop_version >= REMOTE_DESKTOP_PERSISTS {
        SessionKind::RemoteDesktop
    } else {
        SessionKind::ScreenCast
    }
}

/// The session kind a grant asks for: RemoteDesktop when control is allowed and the portal
/// can persist it, else ScreenCast.
pub fn grant_kind(control: bool, remote_desktop_version: u32) -> SessionKind {
    if control && remote_desktop_version >= REMOTE_DESKTOP_PERSISTS {
        SessionKind::RemoteDesktop
    } else {
        SessionKind::ScreenCast
    }
}

/// A started portal session, before its PipeWire stream is opened.
#[derive(Debug)]
pub struct Started {
    pub kind: SessionKind,
    pub session: String,
    pub stream: PortalStream,
    pub devices: u32,
    /// The portal was asked with a saved token (no dialog expected).
    pub restored: bool,
}

/// Picks the cursor mode: embedded in the picture where offered, else metadata.
pub fn pick_cursor_mode(available: u32) -> Option<u32> {
    [CURSOR_EMBEDDED, CURSOR_METADATA].into_iter().find(|m| available & m != 0)
}

/// Runs CreateSession, SelectDevices (RemoteDesktop), SelectSources and Start, reporting
/// each state. Saves the restore token Start returns in the kind's store (and drops a saved
/// one the portal did not honour). On failure after CreateSession the session is closed.
pub fn handshake(
    portal: &mut dyn DesktopPortal,
    kind: SessionKind,
    stores: Option<&TokenStores>,
    on_state: &mut dyn FnMut(PortalState),
) -> Result<Started, PortalError> {
    on_state(PortalState::CreatingSession);
    let store = stores.map(|s| s.for_kind(kind));
    let session = portal.create_session(kind)?;
    let result = (|| {
        let restore_token = store.and_then(RestoreTokenStore::load);
        let cursor_mode = pick_cursor_mode(portal.available_cursor_modes());
        let sources = match kind {
            SessionKind::ScreenCast => SourceSelection {
                types: SOURCE_MONITOR,
                multiple: false,
                cursor_mode,
                persist_mode: PERSIST_UNTIL_REVOKED,
                restore_token: restore_token.clone(),
            },
            SessionKind::RemoteDesktop => {
                portal.select_devices(
                    &session,
                    &DeviceSelection {
                        types: DEVICE_KEYBOARD | DEVICE_POINTER,
                        persist_mode: PERSIST_UNTIL_REVOKED,
                        restore_token: restore_token.clone(),
                    },
                )?;
                // The portal refuses persistence on a RemoteDesktop session's sources.
                SourceSelection {
                    types: SOURCE_MONITOR,
                    multiple: false,
                    cursor_mode,
                    persist_mode: PERSIST_NONE,
                    restore_token: None,
                }
            }
        };
        portal.select_sources(&session, &sources)?;
        on_state(if restore_token.is_some() {
            PortalState::Restoring
        } else {
            PortalState::WaitingForConsent
        });
        let started = match portal.start(kind, &session) {
            Ok(s) => s,
            Err(e) => {
                if e == PortalError::Cancelled {
                    // A dialog was shown, so a saved token no longer applies.
                    if let Some(st) = store {
                        st.clear();
                    }
                }
                return Err(e);
            }
        };
        if let Some(st) = store {
            match &started.restore_token {
                Some(t) => {
                    if let Err(e) = st.save(t) {
                        eprintln!("cmux-rd: portal: could not save the restore token: {e}");
                    }
                }
                None => st.clear(),
            }
        }
        let stream = started
            .streams
            .first()
            .cloned()
            .ok_or_else(|| PortalError::Failed("Start returned no stream".into()))?;
        Ok((stream, started.devices, restore_token.is_some()))
    })();
    match result {
        Ok((stream, devices, restored)) => Ok(Started { kind, session, stream, devices, restored }),
        Err(e) => {
            portal.close_session(&session);
            Err(e)
        }
    }
}

/// What a grant did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Granted {
    pub kind: SessionKind,
    /// The portal was asked with a saved token, so it showed no dialog.
    pub restored: bool,
}

/// Makes the portal grant once, ahead of any share: the handshake of `kind` with no stream,
/// saving its token, then closes the session. With a saved token it shows no dialog and only
/// refreshes the token.
pub fn grant_with(
    portal: &mut dyn DesktopPortal,
    kind: SessionKind,
    stores: &TokenStores,
    on_state: &mut dyn FnMut(PortalState),
) -> Result<Granted, PortalError> {
    let started = handshake(portal, kind, Some(stores), on_state)?;
    portal.close_session(&started.session);
    if kind == SessionKind::RemoteDesktop && started.devices & DEVICE_POINTER == 0 {
        eprintln!("cmux-rd: portal: the grant allows no pointer; control will not move the mouse");
    }
    Ok(Granted { kind, restored: started.restored })
}

/// [`grant_with`] on the session bus's portal and the default stores; `control` asks for
/// RemoteDesktop where the portal can persist it.
/// `on_versions` hears the ScreenCast and RemoteDesktop versions before any dialog shows.
pub fn grant(
    control: bool,
    on_versions: &mut dyn FnMut(u32, u32),
    on_state: &mut dyn FnMut(PortalState),
) -> Result<Granted, PortalError> {
    let stores = TokenStores::default_stores()
        .ok_or_else(|| PortalError::Failed("neither XDG_CONFIG_HOME nor HOME is set".into()))?;
    on_state(PortalState::Connecting);
    let mut portal = ZbusPortal::connect()?;
    let remote_desktop = portal.remote_desktop_version();
    on_versions(portal.screen_cast_version(), remote_desktop);
    let kind = grant_kind(control, remote_desktop);
    grant_with(&mut portal, kind, &stores, on_state)
}

/// Linux evdev button codes (linux/input-event-codes.h).
const BTN_LEFT: i32 = 0x110;
const BTN_RIGHT: i32 = 0x111;
const BTN_MIDDLE: i32 = 0x112;
const BTN_SIDE: i32 = 0x113;
const BTN_EXTRA: i32 = 0x114;
/// NotifyPointerAxisDiscrete axes.
pub const AXIS_VERTICAL: u32 = 0;
pub const AXIS_HORIZONTAL: u32 = 1;

/// One RemoteDesktop Notify call.
#[derive(Clone, Debug, PartialEq)]
pub enum InputCall {
    /// NotifyPointerMotionAbsolute, in the stream's logical pixels.
    Motion { x: f64, y: f64 },
    /// NotifyPointerButton with an evdev button code.
    Button { code: i32, down: bool },
    /// NotifyPointerAxisDiscrete: wheel steps, positive down or right.
    Axis { axis: u32, steps: i32 },
    /// NotifyKeyboardKeycode with an evdev key code.
    Key { code: i32, down: bool },
}

/// The viewer's X-style button number (1 left, 2 middle, 3 right, 8 back, 9 forward) as an
/// evdev code.
fn evdev_button(button: u8) -> Option<i32> {
    match button {
        1 => Some(BTN_LEFT),
        2 => Some(BTN_MIDDLE),
        3 => Some(BTN_RIGHT),
        8 => Some(BTN_SIDE),
        9 => Some(BTN_EXTRA),
        _ => None,
    }
}

/// The Notify calls of one viewer event. `scale` maps the stream's pixels to the logical
/// pixels pointer motion takes (a scaled HiDPI monitor streams more pixels than its logical
/// size). Scroll uses wheel steps, one per 100 units, as the X11 path does.
pub fn input_calls(event: &InputEvent, scale: (f64, f64)) -> Vec<InputCall> {
    match event {
        InputEvent::Key { usage, down } => crate::keymap::hid_to_evdev(*usage)
            .map(|code| InputCall::Key { code: code.into(), down: *down })
            .into_iter()
            .collect(),
        InputEvent::Pointer { x, y } => {
            vec![InputCall::Motion { x: f64::from(*x) * scale.0, y: f64::from(*y) * scale.1 }]
        }
        InputEvent::Button { button, down } => evdev_button(*button)
            .map(|code| InputCall::Button { code, down: *down })
            .into_iter()
            .collect(),
        InputEvent::Scroll { dx, dy, .. } => [(AXIS_VERTICAL, *dy), (AXIS_HORIZONTAL, *dx)]
            .into_iter()
            .filter_map(|(axis, amount)| {
                let steps = (amount / 100).clamp(-20, 20);
                (steps != 0).then_some(InputCall::Axis { axis, steps })
            })
            .collect(),
        // Desktop sessions do not offer the input.service cap.
        InputEvent::Text(_) | InputEvent::Service { .. } => Vec::new(),
    }
}

/// The factor from a stream's pixels to its logical size (1 when the portal gave none).
pub fn logical_scale(logical: Option<(i32, i32)>, pixels: (u32, u32)) -> (f64, f64) {
    match logical {
        Some((lw, lh)) if lw > 0 && lh > 0 && pixels.0 > 0 && pixels.1 > 0 => {
            (f64::from(lw) / f64::from(pixels.0), f64::from(lh) / f64::from(pixels.1))
        }
        _ => (1.0, 1.0),
    }
}

fn unwrap_variant<'a, 'b>(v: &'b Value<'a>) -> &'b Value<'a> {
    match v {
        Value::Value(inner) => unwrap_variant(inner),
        v => v,
    }
}

fn value_string(v: &Value<'_>) -> Option<String> {
    match unwrap_variant(v) {
        Value::Str(s) => Some(s.to_string()),
        Value::ObjectPath(p) => Some(p.as_str().to_string()),
        _ => None,
    }
}

/// Parses Start's results: `streams` (a(ua{sv})), `restore_token` (s) and, for RemoteDesktop,
/// `devices` (u).
pub fn parse_start_results(
    results: &HashMap<String, OwnedValue>,
) -> Result<StartResult, PortalError> {
    let mut out = StartResult {
        restore_token: results.get("restore_token").and_then(|v| value_string(v)),
        devices: match results.get("devices").map(|v| unwrap_variant(v)) {
            Some(Value::U32(d)) => *d,
            _ => 0,
        },
        ..Default::default()
    };
    let Some(streams) = results.get("streams") else {
        return Err(PortalError::Failed("Start returned no streams".into()));
    };
    let Value::Array(arr) = unwrap_variant(streams) else {
        return Err(PortalError::Failed("Start's streams are not an array".into()));
    };
    for item in arr.iter() {
        let Value::Structure(s) = unwrap_variant(item) else { continue };
        let fields = s.fields();
        let Some(Value::U32(node_id)) = fields.first().map(unwrap_variant) else { continue };
        let mut size = None;
        if let Some(Value::Dict(props)) = fields.get(1).map(unwrap_variant) {
            for (k, v) in props.iter() {
                if value_string(k).as_deref() != Some("size") {
                    continue;
                }
                if let Value::Structure(sz) = unwrap_variant(v) {
                    if let [Value::I32(w), Value::I32(h)] = sz.fields() {
                        size = Some((*w, *h));
                    }
                }
            }
        }
        out.streams.push(PortalStream { node_id: *node_id, size });
    }
    Ok(out)
}

pub const PORTAL_DEST: &str = "org.freedesktop.portal.Desktop";
pub const PORTAL_PATH: &str = "/org/freedesktop/portal/desktop";
pub const SCREENCAST_IFACE: &str = "org.freedesktop.portal.ScreenCast";
pub const REMOTE_DESKTOP_IFACE: &str = "org.freedesktop.portal.RemoteDesktop";
pub const REGISTRY_IFACE: &str = "org.freedesktop.host.portal.Registry";

/// The real portal on the session bus. Keep it alive while streaming: the portal ends the
/// session when this connection closes.
pub struct ZbusPortal {
    conn: zbus::blocking::Connection,
    screen_cast: zbus::blocking::Proxy<'static>,
    remote_desktop: zbus::blocking::Proxy<'static>,
    sender: String,
    next_token: u32,
}

fn failed(e: impl std::fmt::Display) -> PortalError {
    PortalError::Failed(e.to_string())
}

impl ZbusPortal {
    /// The ScreenCast interface version (it keeps restore tokens from version 4).
    pub fn screen_cast_version(&self) -> u32 {
        self.screen_cast.get_property::<u32>("version").unwrap_or(0)
    }

    pub fn connect() -> Result<Self, PortalError> {
        let conn = zbus::blocking::Connection::session()
            .map_err(|e| PortalError::Unavailable(e.to_string()))?;
        Self::on(conn)
    }

    /// The portal on `conn` (a session bus; tests pass a private bus with a mock portal).
    pub fn on(conn: zbus::blocking::Connection) -> Result<Self, PortalError> {
        let unavailable = |e: zbus::Error| PortalError::Unavailable(e.to_string());
        // Before any other portal call: the portal fixes a connection's app id at its first.
        // An older portal has no Registry; a sandboxed caller is refused: both keep the id the
        // portal finds by itself.
        let _ = conn.call_method(
            Some(PORTAL_DEST),
            PORTAL_PATH,
            Some(REGISTRY_IFACE),
            "Register",
            &(HOST_APP_ID, HashMap::<&str, Value>::new()),
        );
        let proxy = |iface: &'static str| {
            zbus::blocking::Proxy::new(&conn, PORTAL_DEST, PORTAL_PATH, iface)
        };
        let screen_cast = proxy(SCREENCAST_IFACE).map_err(unavailable)?;
        let remote_desktop = proxy(REMOTE_DESKTOP_IFACE).map_err(unavailable)?;
        // A portal without ScreenCast has no version property.
        screen_cast.get_property::<u32>("version").map_err(unavailable)?;
        let sender = conn
            .unique_name()
            .map(|n| n.as_str().trim_start_matches(':').replace('.', "_"))
            .ok_or_else(|| PortalError::Unavailable("no unique bus name".into()))?;
        Ok(Self { conn, screen_cast, remote_desktop, sender, next_token: 0 })
    }

    fn token(&mut self) -> String {
        self.next_token += 1;
        format!("cmux_rd_{}_{}", std::process::id(), self.next_token)
    }

    fn proxy(&self, kind: SessionKind) -> &zbus::blocking::Proxy<'static> {
        match kind {
            SessionKind::ScreenCast => &self.screen_cast,
            SessionKind::RemoteDesktop => &self.remote_desktop,
        }
    }

    /// Calls `method` on `kind`'s interface and waits for its Request's Response. Subscribes
    /// to the Response on the predicted request path before calling, so a fast answer is not
    /// missed.
    fn request<B>(
        &mut self,
        kind: SessionKind,
        method: &str,
        body: impl FnOnce(String) -> B,
    ) -> Result<HashMap<String, OwnedValue>, PortalError>
    where
        B: serde::Serialize + zbus::zvariant::DynamicType,
    {
        let token = self.token();
        let path = format!("{PORTAL_PATH}/request/{}/{token}", self.sender);
        let req = zbus::blocking::Proxy::new(
            &self.conn,
            PORTAL_DEST,
            path,
            "org.freedesktop.portal.Request",
        )
        .map_err(failed)?;
        let mut responses = req.receive_signal("Response").map_err(failed)?;
        self.proxy(kind).call_method(method, &body(token)).map_err(failed)?;
        let msg = responses
            .next()
            .ok_or_else(|| PortalError::Failed(format!("{method}: no response")))?;
        let (code, results): (u32, HashMap<String, OwnedValue>) =
            msg.body().deserialize().map_err(failed)?;
        response_result(code, results)
    }

    /// Sends one Notify call of a started RemoteDesktop session. Motion is sent without
    /// waiting for a reply (the next one supersedes it); the rest wait, so an error is seen.
    pub fn notify(&self, session: &str, stream: u32, call: &InputCall) -> Result<(), PortalError> {
        let session = ObjectPath::try_from(session).map_err(failed)?;
        let opts: HashMap<&str, Value> = HashMap::new();
        let rd = &self.remote_desktop;
        let state = |down: bool| u32::from(down);
        match *call {
            InputCall::Motion { x, y } => rd
                .call_noreply("NotifyPointerMotionAbsolute", &(session, opts, stream, x, y))
                .map_err(failed),
            InputCall::Button { code, down } => rd
                .call_method("NotifyPointerButton", &(session, opts, code, state(down)))
                .map(drop)
                .map_err(failed),
            InputCall::Axis { axis, steps } => rd
                .call_method("NotifyPointerAxisDiscrete", &(session, opts, axis, steps))
                .map(drop)
                .map_err(failed),
            InputCall::Key { code, down } => rd
                .call_method("NotifyKeyboardKeycode", &(session, opts, code, state(down)))
                .map(drop)
                .map_err(failed),
        }
    }
}

impl DesktopPortal for ZbusPortal {
    fn available_cursor_modes(&mut self) -> u32 {
        self.screen_cast.get_property::<u32>("AvailableCursorModes").unwrap_or(0)
    }

    fn remote_desktop_version(&mut self) -> u32 {
        self.remote_desktop.get_property::<u32>("version").unwrap_or(0)
    }

    fn create_session(&mut self, kind: SessionKind) -> Result<String, PortalError> {
        let session_token = self.token();
        let results = self.request(kind, "CreateSession", |token| {
            let opts: HashMap<&str, Value> = HashMap::from([
                ("handle_token", Value::from(token)),
                ("session_handle_token", Value::from(session_token)),
            ]);
            (opts,)
        })?;
        results
            .get("session_handle")
            .and_then(|v| value_string(v))
            .ok_or_else(|| PortalError::Failed("CreateSession returned no session_handle".into()))
    }

    fn select_devices(&mut self, session: &str, sel: &DeviceSelection) -> Result<(), PortalError> {
        let session = ObjectPath::try_from(session.to_string()).map_err(failed)?;
        let sel = sel.clone();
        self.request(SessionKind::RemoteDesktop, "SelectDevices", move |token| {
            let mut opts: HashMap<&str, Value> = HashMap::from([
                ("handle_token", Value::from(token)),
                ("types", Value::from(sel.types)),
                ("persist_mode", Value::from(sel.persist_mode)),
            ]);
            if let Some(t) = sel.restore_token {
                opts.insert("restore_token", Value::from(t));
            }
            (session, opts)
        })?;
        Ok(())
    }

    fn select_sources(&mut self, session: &str, sel: &SourceSelection) -> Result<(), PortalError> {
        let session = ObjectPath::try_from(session.to_string()).map_err(failed)?;
        let sel = sel.clone();
        self.request(SessionKind::ScreenCast, "SelectSources", move |token| {
            let mut opts: HashMap<&str, Value> = HashMap::from([
                ("handle_token", Value::from(token)),
                ("types", Value::from(sel.types)),
                ("multiple", Value::from(sel.multiple)),
            ]);
            if sel.persist_mode != PERSIST_NONE {
                opts.insert("persist_mode", Value::from(sel.persist_mode));
            }
            if let Some(m) = sel.cursor_mode {
                opts.insert("cursor_mode", Value::from(m));
            }
            if let Some(t) = sel.restore_token {
                opts.insert("restore_token", Value::from(t));
            }
            (session, opts)
        })?;
        Ok(())
    }

    fn start(&mut self, kind: SessionKind, session: &str) -> Result<StartResult, PortalError> {
        let session = ObjectPath::try_from(session.to_string()).map_err(failed)?;
        let results = self.request(kind, "Start", move |token| {
            let opts: HashMap<&str, Value> = HashMap::from([("handle_token", Value::from(token))]);
            (session, "", opts)
        })?;
        parse_start_results(&results)
    }

    fn open_pipewire_remote(&mut self, session: &str) -> Result<OwnedFd, PortalError> {
        let session = ObjectPath::try_from(session).map_err(failed)?;
        let opts: HashMap<&str, Value> = HashMap::new();
        let msg =
            self.screen_cast.call_method("OpenPipeWireRemote", &(session, opts)).map_err(failed)?;
        let fd: zbus::zvariant::OwnedFd = msg.body().deserialize().map_err(failed)?;
        Ok(fd.into())
    }

    fn close_session(&mut self, session: &str) {
        if let Ok(p) = zbus::blocking::Proxy::new(
            &self.conn,
            PORTAL_DEST,
            session.to_string(),
            "org.freedesktop.portal.Session",
        ) {
            let _ = p.call_method("Close", &());
        }
    }
}

/// Options of [`PortalCapture::start`].
#[cfg(feature = "portal")]
pub struct PortalOpts {
    /// Where the restore tokens live; `None` uses [`TokenStores::default_stores`].
    pub token_dir: Option<PathBuf>,
    /// Receives each handshake state (default: a line on stderr).
    pub on_state: Option<Box<dyn FnMut(PortalState) + Send>>,
    /// How long to wait for the first picture once the portal answered.
    pub format_timeout: Duration,
}

#[cfg(feature = "portal")]
impl Default for PortalOpts {
    fn default() -> Self {
        Self { token_dir: None, on_state: None, format_timeout: Duration::from_secs(15) }
    }
}

/// Wayland screen capture through the portal, with `capture::Capturer`'s surface.
#[cfg(feature = "portal")]
pub struct PortalCapture {
    pub width: u32,
    pub height: u32,
    stream: PwStream,
    portal: ZbusPortal,
    started: Started,
}

#[cfg(feature = "portal")]
impl PortalCapture {
    /// Runs the portal handshake (blocking while the consent dialog is up) and starts the
    /// PipeWire stream; returns once the first picture's format is known.
    pub fn start(opts: PortalOpts) -> Res<Self> {
        let PortalOpts { token_dir, on_state, format_timeout } = opts;
        let mut on_state: Box<dyn FnMut(PortalState) + Send> = on_state.unwrap_or_else(|| {
            Box::new(|s: PortalState| eprintln!("cmux-rd: portal: {}", s.message()))
        });
        on_state(PortalState::Connecting);
        let mut portal = ZbusPortal::connect()?;
        let stores = match token_dir {
            Some(dir) => Some(TokenStores::in_dir(&dir)),
            None => TokenStores::default_stores(),
        };
        let kind = session_kind(stores.as_ref(), portal.remote_desktop_version());
        let started = handshake(&mut portal, kind, stores.as_ref(), &mut *on_state)?;
        let stream = match portal
            .open_pipewire_remote(&started.session)
            .map_err(Into::into)
            .and_then(|fd| PwStream::start(fd, started.stream.node_id, format_timeout))
        {
            Ok(s) => s,
            Err(e) => {
                portal.close_session(&started.session);
                return Err(e);
            }
        };
        on_state(PortalState::Streaming { width: stream.width, height: stream.height });
        Ok(Self { width: stream.width, height: stream.height, stream, portal, started })
    }

    /// Whether this capture's session applies input (a RemoteDesktop session with devices).
    pub fn applies_input(&self) -> bool {
        self.started.kind == SessionKind::RemoteDesktop && self.started.devices != 0
    }

    /// Readable when [`PortalCapture::drain`] has damage to report.
    pub fn fd(&self) -> RawFd {
        self.stream.fd()
    }

    /// Takes every queued damage report without blocking; fails once the cast ended.
    pub fn drain(&mut self, out: &mut Vec<DamageEvent>) -> Res<()> {
        self.stream.drain(out)
    }

    /// A reader of the newest picture for the session's encode thread.
    pub fn frames(&self) -> crate::pipewire_capture::PwFrames {
        self.stream.frames()
    }
}

#[cfg(feature = "portal")]
impl Drop for PortalCapture {
    fn drop(&mut self) {
        self.portal.close_session(&self.started.session);
    }
}

/// [`PortalCapture`] as a session's `Desktop`: damage, and the viewer's input through the
/// RemoteDesktop session (a ScreenCast session drops it: view only).
#[cfg(feature = "portal")]
pub struct PortalDesktop {
    cap: PortalCapture,
    damage: Vec<DamageEvent>,
    warned_input: bool,
    scale: (f64, f64),
    /// Keys and buttons the viewer holds (evdev codes), released when control ends.
    keys: std::collections::BTreeSet<i32>,
    buttons: std::collections::BTreeSet<i32>,
}

/// The portal's encode-thread half: the same I420 conversion and encoder as the X11 desktop.
#[cfg(feature = "portal")]
pub struct PortalFrames {
    frames: crate::pipewire_capture::PwFrames,
    width: u32,
    height: u32,
    enc: Box<dyn crate::encoder::H264Encoder>,
    pic: cmux_encode::I420,
}

/// Runs the portal handshake and opens both halves of the session's desktop.
#[cfg(feature = "portal")]
pub fn open_desktop(
    cfg: &crate::stream::SessionCfg,
    opts: PortalOpts,
) -> Res<crate::desktop::Halves> {
    let cap = PortalCapture::start(opts)?;
    let (w, h) = (cap.width & !1, cap.height & !1);
    let enc = crate::encoder::open(&crate::encoder::EncCfg {
        width: w,
        height: h,
        fps: cfg.max_fps,
        kbps: cfg.start_kbps,
        threads: cfg.threads,
        codec: &cfg.codec,
        screen_content: cfg.content != "camera",
        preset: &cfg.preset,
        profile: &cfg.profile,
        openh264_lib: cfg.openh264_lib.as_deref(),
    })?;
    let frames = PortalFrames {
        frames: cap.frames(),
        width: w,
        height: h,
        pic: cmux_encode::I420::new(w as usize, h as usize),
        enc,
    };
    let scale = logical_scale(cap.started.stream.size, (cap.width, cap.height));
    let desktop = PortalDesktop {
        cap,
        damage: Vec::new(),
        warned_input: false,
        scale,
        keys: Default::default(),
        buttons: Default::default(),
    };
    Ok((Box::new(desktop), Box::new(frames)))
}

#[cfg(feature = "portal")]
impl crate::desktop::Desktop for PortalDesktop {
    fn size(&self) -> (u32, u32) {
        (self.cap.width & !1, self.cap.height & !1)
    }

    fn fd(&self) -> RawFd {
        self.cap.fd()
    }

    fn drain(&mut self, out: &mut Vec<cmux_rd_core::flow::Rect>) -> Res<()> {
        self.damage.clear();
        self.cap.drain(&mut self.damage)?;
        out.extend(self.damage.iter().map(|ev| cmux_rd_core::flow::Rect {
            x: ev.rect.x,
            y: ev.rect.y,
            width: ev.rect.w,
            height: ev.rect.h,
        }));
        Ok(())
    }

    fn inject(&mut self, event: &cmux_rd_proto::InputEvent) -> Res<()> {
        if !self.cap.applies_input() {
            if !self.warned_input {
                self.warned_input = true;
                eprintln!(
                    "cmux-rd: this portal session has no RemoteDesktop grant; viewer input is ignored (run `cmux-rd linux-host grant --control`)"
                );
            }
            return Ok(());
        }
        let session = &self.cap.started.session;
        let node = self.cap.started.stream.node_id;
        for call in input_calls(event, self.scale) {
            self.cap.portal.notify(session, node, &call)?;
            match call {
                InputCall::Key { code, down: true } => drop(self.keys.insert(code)),
                InputCall::Key { code, down: false } => drop(self.keys.remove(&code)),
                InputCall::Button { code, down: true } => drop(self.buttons.insert(code)),
                InputCall::Button { code, down: false } => drop(self.buttons.remove(&code)),
                _ => {}
            }
        }
        Ok(())
    }

    fn release_all(&mut self) -> Res<()> {
        let session = &self.cap.started.session;
        let node = self.cap.started.stream.node_id;
        for code in std::mem::take(&mut self.keys) {
            self.cap.portal.notify(session, node, &InputCall::Key { code, down: false })?;
        }
        for code in std::mem::take(&mut self.buttons) {
            self.cap.portal.notify(session, node, &InputCall::Button { code, down: false })?;
        }
        Ok(())
    }
}

#[cfg(feature = "portal")]
impl crate::desktop::FrameSource for PortalFrames {
    fn capture(&mut self, damage: cmux_rd_core::flow::Rect) -> Res<()> {
        let r = Rect { x: damage.x, y: damage.y, w: damage.width, h: damage.height }
            .align_even(self.width, self.height);
        if r.w > 0 && r.h > 0 {
            let px = self.frames.grab(r)?;
            cmux_encode::bgrx_rect_to_i420(
                px,
                &mut self.pic,
                r.x as usize,
                r.y as usize,
                r.w as usize,
                r.h as usize,
                cmux_encode::convert_threads(),
            );
        }
        Ok(())
    }

    fn encode(&mut self, force_idr: bool, pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
        self.enc.encode(&self.pic, force_idr, pts_us, out)
    }

    fn set_bitrate(&mut self, kbps: u32) {
        self.enc.set_bitrate(kbps);
    }

    fn kbps(&self) -> u32 {
        self.enc.kbps()
    }

    fn encoder_name(&self) -> String {
        self.enc.name()
    }

    fn idr_cause(&self) -> Option<&'static str> {
        self.enc.idr_cause()
    }
}

#[cfg(test)]
#[path = "portal_mock_bus_tests.rs"]
mod mock_bus_tests;

#[cfg(test)]
#[path = "portal_tests.rs"]
mod tests;
