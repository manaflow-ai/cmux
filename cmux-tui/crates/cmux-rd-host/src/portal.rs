//! Wayland screen capture (feature `portal`, Linux): the xdg-desktop-portal ScreenCast
//! handshake over D-Bus, then the PipeWire stream it opens (src/pipewire_capture.rs).
//! It lets a viewer watch a Wayland desktop (a GNOME-style seat0 session with no X server).
//!
//! # How serve plugs it in
//! [`PortalCapture::start`] is the one constructor. It returns a capturer with the same
//! surface as `capture::Capturer` on X11: `width`/`height`, [`PortalCapture::fd`] (readable
//! when damage waits), [`PortalCapture::drain`] (damage as `capture::DamageEvent`) and
//! [`PortalCapture::grab`] (a rectangle as BGRX rows of stride `w * 4`). [`PortalDesktop`]
//! wraps it as a `desktop::Desktop` with the session's encoder, so the capture-backend seam
//! (`--capture portal|x11`, chosen by the session in serve/host) only has to call
//! `PortalDesktop::open(cfg, PortalOpts::default())` where it now calls `X11Desktop::open`.
//!
//! # Handshake
//! CreateSession, SelectSources (one monitor, cursor embedded where offered, else as
//! metadata, `persist_mode` 2 with the saved `restore_token`), Start, OpenPipeWireRemote.
//! Each Start returns a new restore token; it is saved in the user's config directory
//! ([`RestoreTokenStore`]), so the person at the screen allows sharing once and later
//! sessions start with no dialog. Without a token the portal shows its dialog on the seat
//! and the handshake reports [`PortalState::WaitingForConsent`] until they answer.
//!
//! # View-only
//! Input injection on Wayland (the RemoteDesktop portal or libei) is out of scope: the
//! viewer can watch but not type or click; [`PortalDesktop`] drops input events.

use crate::capture::{DamageEvent, Rect};
use crate::pipewire_capture::PwStream;
use crate::Res;
use std::collections::HashMap;
use std::os::fd::{OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use std::time::Duration;
use zbus::zvariant::{ObjectPath, OwnedValue, Value};

/// SelectSources `types`: a monitor.
pub const SOURCE_MONITOR: u32 = 1;
/// `cursor_mode` bits (AvailableCursorModes).
pub const CURSOR_HIDDEN: u32 = 1;
pub const CURSOR_EMBEDDED: u32 = 2;
pub const CURSOR_METADATA: u32 = 4;
/// `persist_mode`: until the person revokes it.
pub const PERSIST_UNTIL_REVOKED: u32 = 2;

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

/// One stream of a Start response.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PortalStream {
    pub node_id: u32,
    pub size: Option<(i32, i32)>,
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct StartResult {
    pub streams: Vec<PortalStream>,
    pub restore_token: Option<String>,
}

/// The ScreenCast portal calls the handshake makes. [`ZbusPortal`] talks to the real portal
/// over the session bus; tests drive the handshake with a fake.
pub trait ScreenCastPortal {
    /// The AvailableCursorModes bits (0 when the portal predates cursor modes).
    fn available_cursor_modes(&mut self) -> u32;
    /// Returns the session handle.
    fn create_session(&mut self) -> Result<String, PortalError>;
    fn select_sources(&mut self, session: &str, sel: &SourceSelection) -> Result<(), PortalError>;
    /// Blocks until the portal answers (with a dialog, until the person does).
    fn start(&mut self, session: &str) -> Result<StartResult, PortalError>;
    fn open_pipewire_remote(&mut self, session: &str) -> Result<OwnedFd, PortalError>;
    fn close_session(&mut self, session: &str);
}

/// Saves the portal's restore token: `$XDG_CONFIG_HOME/cmux/rd-portal-restore-token`
/// (else `~/.config/...`), mode 0600.
#[derive(Clone, Debug)]
pub struct RestoreTokenStore {
    path: PathBuf,
}

impl RestoreTokenStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    /// The per-user default path, or `None` with neither `XDG_CONFIG_HOME` nor `HOME` set.
    pub fn default_path() -> Option<PathBuf> {
        let abs = |k: &str| std::env::var_os(k).map(PathBuf::from).filter(|p| p.is_absolute());
        let dir = abs("XDG_CONFIG_HOME").or_else(|| Some(abs("HOME")?.join(".config")))?;
        Some(dir.join("cmux").join("rd-portal-restore-token"))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&self) -> Option<String> {
        let s = std::fs::read_to_string(&self.path).ok()?;
        let t = s.trim();
        (!t.is_empty()).then(|| t.to_string())
    }

    /// Writes the token atomically (a temporary file renamed over the old one).
    pub fn save(&self, token: &str) -> std::io::Result<()> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
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
        std::fs::rename(&tmp, &self.path)
    }

    pub fn clear(&self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// What a finished handshake hands to PipeWire.
#[derive(Debug)]
pub struct Handshake {
    pub session: String,
    pub stream: PortalStream,
    pub fd: OwnedFd,
}

/// Picks the cursor mode: embedded in the picture where offered, else metadata.
pub fn pick_cursor_mode(available: u32) -> Option<u32> {
    [CURSOR_EMBEDDED, CURSOR_METADATA].into_iter().find(|m| available & m != 0)
}

/// Runs CreateSession, SelectSources, Start and OpenPipeWireRemote, reporting each state.
/// Saves the restore token Start returns (and drops a saved one the portal did not honour).
/// On failure after CreateSession the session is closed.
pub fn handshake(
    portal: &mut dyn ScreenCastPortal,
    store: Option<&RestoreTokenStore>,
    on_state: &mut dyn FnMut(PortalState),
) -> Result<Handshake, PortalError> {
    on_state(PortalState::CreatingSession);
    let session = portal.create_session()?;
    let result = (|| {
        let restore_token = store.and_then(RestoreTokenStore::load);
        let sel = SourceSelection {
            types: SOURCE_MONITOR,
            multiple: false,
            cursor_mode: pick_cursor_mode(portal.available_cursor_modes()),
            persist_mode: PERSIST_UNTIL_REVOKED,
            restore_token: restore_token.clone(),
        };
        portal.select_sources(&session, &sel)?;
        on_state(if restore_token.is_some() {
            PortalState::Restoring
        } else {
            PortalState::WaitingForConsent
        });
        let started = match portal.start(&session) {
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
        let fd = portal.open_pipewire_remote(&session)?;
        Ok((stream, fd))
    })();
    match result {
        Ok((stream, fd)) => Ok(Handshake { session, stream, fd }),
        Err(e) => {
            portal.close_session(&session);
            Err(e)
        }
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

/// Parses Start's results: `streams` (a(ua{sv})) and `restore_token` (s).
pub fn parse_start_results(
    results: &HashMap<String, OwnedValue>,
) -> Result<StartResult, PortalError> {
    let mut out = StartResult {
        restore_token: results.get("restore_token").and_then(|v| value_string(v)),
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

const PORTAL_DEST: &str = "org.freedesktop.portal.Desktop";
const PORTAL_PATH: &str = "/org/freedesktop/portal/desktop";
const SCREENCAST_IFACE: &str = "org.freedesktop.portal.ScreenCast";

/// The real ScreenCast portal on the session bus. Keep it alive while streaming: the portal
/// ends the session when this connection closes.
pub struct ZbusPortal {
    conn: zbus::blocking::Connection,
    proxy: zbus::blocking::Proxy<'static>,
    sender: String,
    next_token: u32,
}

fn failed(e: impl std::fmt::Display) -> PortalError {
    PortalError::Failed(e.to_string())
}

impl ZbusPortal {
    pub fn connect() -> Result<Self, PortalError> {
        let unavailable = |e: zbus::Error| PortalError::Unavailable(e.to_string());
        let conn = zbus::blocking::Connection::session().map_err(unavailable)?;
        let proxy = zbus::blocking::Proxy::new(&conn, PORTAL_DEST, PORTAL_PATH, SCREENCAST_IFACE)
            .map_err(unavailable)?;
        // A portal without ScreenCast has no version property.
        proxy.get_property::<u32>("version").map_err(unavailable)?;
        let sender = conn
            .unique_name()
            .map(|n| n.as_str().trim_start_matches(':').replace('.', "_"))
            .ok_or_else(|| PortalError::Unavailable("no unique bus name".into()))?;
        Ok(Self { conn, proxy, sender, next_token: 0 })
    }

    fn token(&mut self) -> String {
        self.next_token += 1;
        format!("cmux_rd_{}_{}", std::process::id(), self.next_token)
    }

    /// Calls `method` and waits for its Request's Response. Subscribes to the Response on the
    /// predicted request path before calling, so a fast answer is not missed.
    fn request<B>(
        &mut self,
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
        self.proxy.call_method(method, &body(token)).map_err(failed)?;
        let msg = responses
            .next()
            .ok_or_else(|| PortalError::Failed(format!("{method}: no response")))?;
        let (code, results): (u32, HashMap<String, OwnedValue>) =
            msg.body().deserialize().map_err(failed)?;
        response_result(code, results)
    }
}

impl ScreenCastPortal for ZbusPortal {
    fn available_cursor_modes(&mut self) -> u32 {
        self.proxy.get_property::<u32>("AvailableCursorModes").unwrap_or(0)
    }

    fn create_session(&mut self) -> Result<String, PortalError> {
        let session_token = self.token();
        let results = self.request("CreateSession", |token| {
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

    fn select_sources(&mut self, session: &str, sel: &SourceSelection) -> Result<(), PortalError> {
        let session = ObjectPath::try_from(session.to_string()).map_err(failed)?;
        let sel = sel.clone();
        self.request("SelectSources", move |token| {
            let mut opts: HashMap<&str, Value> = HashMap::from([
                ("handle_token", Value::from(token)),
                ("types", Value::from(sel.types)),
                ("multiple", Value::from(sel.multiple)),
                ("persist_mode", Value::from(sel.persist_mode)),
            ]);
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

    fn start(&mut self, session: &str) -> Result<StartResult, PortalError> {
        let session = ObjectPath::try_from(session.to_string()).map_err(failed)?;
        let results = self.request("Start", move |token| {
            let opts: HashMap<&str, Value> = HashMap::from([("handle_token", Value::from(token))]);
            (session, "", opts)
        })?;
        parse_start_results(&results)
    }

    fn open_pipewire_remote(&mut self, session: &str) -> Result<OwnedFd, PortalError> {
        let session = ObjectPath::try_from(session).map_err(failed)?;
        let opts: HashMap<&str, Value> = HashMap::new();
        let msg = self.proxy.call_method("OpenPipeWireRemote", &(session, opts)).map_err(failed)?;
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
pub struct PortalOpts {
    /// Where the restore token lives; `None` uses [`RestoreTokenStore::default_path`].
    pub token_path: Option<PathBuf>,
    /// Receives each handshake state (default: a line on stderr).
    pub on_state: Option<Box<dyn FnMut(PortalState) + Send>>,
    /// How long to wait for the first picture once the portal answered.
    pub format_timeout: Duration,
}

impl Default for PortalOpts {
    fn default() -> Self {
        Self { token_path: None, on_state: None, format_timeout: Duration::from_secs(15) }
    }
}

/// Wayland screen capture through the ScreenCast portal, with `capture::Capturer`'s surface.
pub struct PortalCapture {
    pub width: u32,
    pub height: u32,
    stream: PwStream,
    portal: ZbusPortal,
    session: String,
}

impl PortalCapture {
    /// Runs the portal handshake (blocking while the consent dialog is up) and starts the
    /// PipeWire stream; returns once the first picture's format is known.
    pub fn start(opts: PortalOpts) -> Res<Self> {
        let PortalOpts { token_path, on_state, format_timeout } = opts;
        let mut on_state: Box<dyn FnMut(PortalState) + Send> = on_state.unwrap_or_else(|| {
            Box::new(|s: PortalState| eprintln!("cmux-rd: portal: {}", s.message()))
        });
        on_state(PortalState::Connecting);
        let mut portal = ZbusPortal::connect()?;
        let store = token_path.or_else(RestoreTokenStore::default_path).map(RestoreTokenStore::new);
        let hs = handshake(&mut portal, store.as_ref(), &mut *on_state)?;
        let stream = match PwStream::start(hs.fd, hs.stream.node_id, format_timeout) {
            Ok(s) => s,
            Err(e) => {
                portal.close_session(&hs.session);
                return Err(e);
            }
        };
        on_state(PortalState::Streaming { width: stream.width, height: stream.height });
        Ok(Self { width: stream.width, height: stream.height, stream, portal, session: hs.session })
    }

    /// Readable when [`PortalCapture::drain`] has damage to report.
    pub fn fd(&self) -> RawFd {
        self.stream.fd()
    }

    /// Takes every queued damage report without blocking; fails once the cast ended.
    pub fn drain(&mut self, out: &mut Vec<DamageEvent>) -> Res<()> {
        self.stream.drain(out)
    }

    /// Copies `r` of the newest picture out as BGRX rows with stride `r.w * 4`.
    pub fn grab(&mut self, r: Rect) -> Res<&[u8]> {
        self.stream.grab(r)
    }
}

impl Drop for PortalCapture {
    fn drop(&mut self) {
        self.portal.close_session(&self.session);
    }
}

/// [`PortalCapture`] as a session's `Desktop`: the same I420 conversion and encoder as the
/// X11 desktop, and no input (view-only: events are dropped).
pub struct PortalDesktop {
    cap: PortalCapture,
    enc: Box<dyn crate::encoder::H264Encoder>,
    pic: cmux_encode::I420,
    damage: Vec<DamageEvent>,
    warned_input: bool,
}

impl PortalDesktop {
    pub fn open(cfg: &crate::stream::SessionCfg, opts: PortalOpts) -> Res<Self> {
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
        Ok(Self {
            pic: cmux_encode::I420::new(w as usize, h as usize),
            damage: Vec::new(),
            cap,
            enc,
            warned_input: false,
        })
    }
}

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

    fn capture(&mut self, damage: cmux_rd_core::flow::Rect) -> Res<()> {
        let (w, h) = self.size();
        let r =
            Rect { x: damage.x, y: damage.y, w: damage.width, h: damage.height }.align_even(w, h);
        if r.w > 0 && r.h > 0 {
            let px = self.cap.grab(r)?;
            cmux_encode::bgrx_rect_to_i420(
                px,
                &mut self.pic,
                r.x as usize,
                r.y as usize,
                r.w as usize,
                r.h as usize,
                2,
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

    fn inject(&mut self, _event: &cmux_rd_proto::InputEvent) -> Res<()> {
        if !self.warned_input {
            self.warned_input = true;
            eprintln!("cmux-rd: portal capture is view-only; viewer input is ignored on Wayland");
        }
        Ok(())
    }

    fn release_all(&mut self) -> Res<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    fn temp_store(name: &str) -> RestoreTokenStore {
        let nanos =
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir()
            .join(format!("cmux-rd-portal-{}-{name}-{nanos}", std::process::id()));
        RestoreTokenStore::new(dir.join("cmux").join("rd-portal-restore-token"))
    }

    fn cleanup(store: &RestoreTokenStore) {
        let root = store.path().parent().and_then(Path::parent).unwrap();
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn token_store_round_trips_with_private_mode() {
        use std::os::unix::fs::PermissionsExt;
        let store = temp_store("rt");
        assert_eq!(store.load(), None);
        store.save("tok-1").unwrap();
        assert_eq!(store.load().as_deref(), Some("tok-1"));
        let mode = std::fs::metadata(store.path()).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        store.save("tok-2").unwrap();
        assert_eq!(store.load().as_deref(), Some("tok-2"));
        store.clear();
        assert_eq!(store.load(), None);
        cleanup(&store);
    }

    #[test]
    fn token_store_ignores_blank_files() {
        let store = temp_store("blank");
        store.save("  \n").unwrap();
        assert_eq!(store.load(), None);
        cleanup(&store);
    }

    #[test]
    fn response_codes_map_to_results() {
        assert_eq!(response_result(0, 7), Ok(7));
        assert_eq!(response_result(1, 7), Err(PortalError::Cancelled));
        assert!(matches!(response_result(2, 7), Err(PortalError::Failed(_))));
    }

    #[test]
    fn cursor_mode_prefers_embedded_then_metadata() {
        assert_eq!(
            pick_cursor_mode(CURSOR_HIDDEN | CURSOR_EMBEDDED | CURSOR_METADATA),
            Some(CURSOR_EMBEDDED)
        );
        assert_eq!(pick_cursor_mode(CURSOR_HIDDEN | CURSOR_METADATA), Some(CURSOR_METADATA));
        assert_eq!(pick_cursor_mode(0), None);
    }

    #[test]
    fn start_results_parse_streams_and_token() {
        let props: HashMap<String, Value> =
            HashMap::from([("size".to_string(), Value::from((2560i32, 1440i32)))]);
        let streams = Value::from(vec![(57u32, props)]);
        let results: HashMap<String, OwnedValue> = HashMap::from([
            ("streams".to_string(), OwnedValue::try_from(streams).unwrap()),
            ("restore_token".to_string(), OwnedValue::try_from(Value::from("tok")).unwrap()),
        ]);
        let got = parse_start_results(&results).unwrap();
        assert_eq!(got.restore_token.as_deref(), Some("tok"));
        assert_eq!(got.streams, vec![PortalStream { node_id: 57, size: Some((2560, 1440)) }]);
        assert!(parse_start_results(&HashMap::new()).is_err());
    }

    /// A fake ScreenCast portal: records each call and answers Start as told.
    struct FakePortal {
        calls: Rc<RefCell<Vec<String>>>,
        cursor_modes: u32,
        start: Result<StartResult, PortalError>,
        selected: Option<SourceSelection>,
    }

    impl FakePortal {
        fn new(start: Result<StartResult, PortalError>) -> Self {
            Self {
                calls: Rc::new(RefCell::new(Vec::new())),
                cursor_modes: CURSOR_HIDDEN | CURSOR_EMBEDDED,
                start,
                selected: None,
            }
        }
    }

    impl ScreenCastPortal for FakePortal {
        fn available_cursor_modes(&mut self) -> u32 {
            self.cursor_modes
        }
        fn create_session(&mut self) -> Result<String, PortalError> {
            self.calls.borrow_mut().push("create".into());
            Ok("/org/freedesktop/portal/desktop/session/1_1/s".into())
        }
        fn select_sources(&mut self, _s: &str, sel: &SourceSelection) -> Result<(), PortalError> {
            self.calls.borrow_mut().push("select".into());
            self.selected = Some(sel.clone());
            Ok(())
        }
        fn start(&mut self, _s: &str) -> Result<StartResult, PortalError> {
            self.calls.borrow_mut().push("start".into());
            self.start.clone()
        }
        fn open_pipewire_remote(&mut self, _s: &str) -> Result<OwnedFd, PortalError> {
            self.calls.borrow_mut().push("open".into());
            Ok(std::fs::File::open("/dev/null").unwrap().into())
        }
        fn close_session(&mut self, _s: &str) {
            self.calls.borrow_mut().push("close".into());
        }
    }

    fn started(token: Option<&str>) -> StartResult {
        StartResult {
            streams: vec![PortalStream { node_id: 42, size: Some((1920, 1080)) }],
            restore_token: token.map(str::to_string),
        }
    }

    #[test]
    fn first_run_waits_for_consent_and_saves_the_token() {
        let store = temp_store("first");
        let mut portal = FakePortal::new(Ok(started(Some("granted"))));
        let mut states = Vec::new();
        let hs = handshake(&mut portal, Some(&store), &mut |s| states.push(s)).unwrap();
        assert_eq!(hs.stream.node_id, 42);
        assert_eq!(*portal.calls.borrow(), ["create", "select", "start", "open"]);
        assert_eq!(states, [PortalState::CreatingSession, PortalState::WaitingForConsent]);
        let sel = portal.selected.unwrap();
        assert_eq!(sel.types, SOURCE_MONITOR);
        assert_eq!(sel.persist_mode, PERSIST_UNTIL_REVOKED);
        assert_eq!(sel.cursor_mode, Some(CURSOR_EMBEDDED));
        assert_eq!(sel.restore_token, None);
        assert_eq!(store.load().as_deref(), Some("granted"));
        cleanup(&store);
    }

    #[test]
    fn saved_token_restores_without_a_dialog_and_rotates() {
        let store = temp_store("restore");
        store.save("old").unwrap();
        let mut portal = FakePortal::new(Ok(started(Some("new"))));
        let mut states = Vec::new();
        handshake(&mut portal, Some(&store), &mut |s| states.push(s)).unwrap();
        assert_eq!(portal.selected.unwrap().restore_token.as_deref(), Some("old"));
        assert_eq!(states, [PortalState::CreatingSession, PortalState::Restoring]);
        assert_eq!(store.load().as_deref(), Some("new"));
        cleanup(&store);
    }

    #[test]
    fn declined_dialog_closes_the_session_and_drops_the_token() {
        let store = temp_store("declined");
        store.save("stale").unwrap();
        let mut portal = FakePortal::new(Err(PortalError::Cancelled));
        let err = handshake(&mut portal, Some(&store), &mut |_| {}).unwrap_err();
        assert_eq!(err, PortalError::Cancelled);
        assert_eq!(*portal.calls.borrow(), ["create", "select", "start", "close"]);
        assert_eq!(store.load(), None);
        cleanup(&store);
    }

    #[test]
    fn start_without_streams_fails_and_closes() {
        let mut portal = FakePortal::new(Ok(StartResult::default()));
        let err = handshake(&mut portal, None, &mut |_| {}).unwrap_err();
        assert!(matches!(err, PortalError::Failed(_)));
        assert_eq!(*portal.calls.borrow(), ["create", "select", "start", "close"]);
    }

    #[test]
    fn waiting_state_names_the_person_at_the_screen() {
        assert_eq!(
            PortalState::WaitingForConsent.message(),
            "waiting for the person at the screen to allow sharing"
        );
    }
}
