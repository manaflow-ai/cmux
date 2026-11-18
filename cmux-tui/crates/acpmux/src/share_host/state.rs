//! What the running share host knows, shared by its hub link, the app's device channel and
//! `_acpmux/share_host_status`: the hub client (its device), the link's state, the app channels
//! subscribed to pushes, the hub's device list, and what the app told the channel.

use super::{NotRunning, records};
use cmux_hub_host::hub::Hub;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use tokio::sync::mpsc::UnboundedSender;

/// The status JSON's schema.
pub(crate) const SCHEMA: &str = "acpmux.share-host.status/1";

/// The link's state, as `share-host status` names it.
#[derive(Debug, Clone, Default)]
pub(crate) struct Link {
    /// `starting`, `signing_in`, `sign_in_failed`, `online`, `offline`, `stopped`.
    pub state: &'static str,
    /// The last error, one line.
    pub detail: Option<String>,
    /// The hub's error code of the last error (`account_not_on_hub`, `machine_no_person`, ...).
    pub code: Option<String>,
    /// When the next sign-in is tried, ms since the epoch.
    pub retry_at_ms: Option<u64>,
    /// The hub's `macScreenShared` for this device, from the last registration or list.
    pub sharing: Option<bool>,
    pub share_by_join: Option<bool>,
    /// Whether the last `PUT /v1/devices/:id/screen-share` went through.
    pub screen_share_sent: Option<bool>,
}

/// What the app told the device channel (accepted, recorded for status).
#[derive(Debug, Clone, Default)]
pub(crate) struct AppNotes {
    pub host_mode: Option<Value>,
    pub consent: Option<Value>,
    pub anchored: Option<Value>,
    pub signed_out: bool,
}

pub(crate) struct Shared {
    pub home: PathBuf,
    hub: Mutex<Arc<Hub>>,
    link: Mutex<Link>,
    subscribers: Mutex<Vec<UnboundedSender<String>>>,
    pub app: Mutex<AppNotes>,
    /// The hub's devices: id -> platform.
    devices: Mutex<HashMap<String, String>>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

static RUNNING: OnceLock<Arc<Shared>> = OnceLock::new();
static NOT_RUNNING: Mutex<Option<NotRunning>> = Mutex::new(None);

/// Records why this daemon runs no share host.
pub(crate) fn not_running(why: NotRunning) {
    *lock(&NOT_RUNNING) = Some(why);
}

impl Shared {
    pub(crate) fn new(home: PathBuf, hub: Hub) -> Arc<Self> {
        Arc::new(Self {
            home,
            hub: Mutex::new(Arc::new(hub)),
            link: Mutex::new(Link { state: "starting", ..Link::default() }),
            subscribers: Mutex::new(Vec::new()),
            app: Mutex::new(AppNotes::default()),
            devices: Mutex::new(HashMap::new()),
        })
    }

    /// [`Shared::new`], as this daemon's one share host (what status reads).
    pub(crate) fn install(home: PathBuf, hub: Hub) -> Arc<Self> {
        let shared = Self::new(home, hub);
        let _ = RUNNING.set(shared.clone());
        shared
    }

    pub(crate) fn hub(&self) -> Arc<Hub> {
        lock(&self.hub).clone()
    }

    /// A new hub client: the device registered as new after the hub refused the old one.
    pub(crate) fn set_hub(&self, hub: Hub) {
        *lock(&self.hub) = Arc::new(hub);
    }

    pub(crate) fn link(&self) -> Link {
        lock(&self.link).clone()
    }

    pub(crate) fn update_link(&self, change: impl FnOnce(&mut Link)) {
        change(&mut lock(&self.link));
    }

    /// A new app channel that gets every push.
    pub(crate) fn subscribe(&self, sender: UnboundedSender<String>) {
        lock(&self.subscribers).push(sender);
    }

    /// Whether an app is attached: a subscribed channel still open.
    pub(crate) fn app_attached(&self) -> bool {
        let mut subscribers = lock(&self.subscribers);
        subscribers.retain(|s| !s.is_closed());
        !subscribers.is_empty()
    }

    /// Sends `text` (a push) to every subscribed app channel.
    pub(crate) fn relay(&self, text: &str) {
        let line = json!({"event": "push", "text": text}).to_string();
        lock(&self.subscribers).retain(|s| s.send(line.clone()).is_ok());
    }

    pub(crate) fn set_devices(&self, devices: &Value) {
        let mut map = HashMap::new();
        let own = self.hub().device.id.clone();
        for device in devices.get("devices").and_then(Value::as_array).into_iter().flatten() {
            let field = |k: &str| device.get(k).and_then(Value::as_str).map(str::to_owned);
            if let (Some(id), Some(platform)) = (field("id"), field("platform")) {
                if id == own {
                    let shared = device.get("macScreenShared").and_then(Value::as_bool);
                    self.update_link(|link| link.sharing = shared.or(link.sharing));
                }
                map.insert(id, platform);
            }
        }
        *lock(&self.devices) = map;
    }

    /// The hub's platform of device `id`, when listed.
    pub(crate) fn platform_of(&self, id: &str) -> Option<String> {
        lock(&self.devices).get(id).cloned()
    }

    /// `share-host status`'s answer.
    pub(crate) fn status_json(&self) -> Value {
        let hub = self.hub();
        let link = self.link();
        let app = lock(&self.app).clone();
        let sessions: Vec<Value> = records::live(&records::dir(&self.home), records::Record::alive)
            .into_iter()
            .map(|r| {
                json!({"sessionId": r.session_id, "scope": r.scope, "viewerId": r.viewer_id,
                       "viewerName": r.viewer_name, "pid": r.pid})
            })
            .collect();
        json!({
            "schema": SCHEMA,
            "running": true,
            "state": link.state,
            "detail": link.detail,
            "code": link.code,
            "retryAtMs": link.retry_at_ms,
            "linkUp": link.state == "online",
            "hub": hub.origin,
            "deviceId": hub.device.id,
            "deviceName": hub.device.name,
            "userId": hub.user_id(),
            "sharing": link.sharing,
            "shareByJoin": link.share_by_join,
            "screenShareSent": link.screen_share_sent,
            "sessions": sessions,
            "helper": super::helper::status_json(&self.home),
            "appAttached": self.app_attached(),
            "app": {
                "hostMode": app.host_mode,
                "consent": app.consent,
                "anchored": app.anchored,
                "signedOut": app.signed_out,
            },
        })
    }
}

/// `share-host status` in this daemon: the running host's, or why it does not run.
pub(crate) fn status_now() -> Value {
    if let Some(shared) = RUNNING.get() {
        return shared.status_json();
    }
    let why = lock(&NOT_RUNNING).clone();
    not_running_json(why.as_ref(), cfg!(target_os = "macos"))
}

/// The status of a share host that does not run, and why.
pub(crate) fn not_running_json(why: Option<&NotRunning>, mac: bool) -> Value {
    let (state, detail) = match why {
        Some(why) => (why.code, why.detail.clone()),
        None if !mac => ("unsupported", "the share host runs on macOS".to_owned()),
        None => ("not_started", "this daemon did not start the share host".to_owned()),
    };
    json!({"schema": SCHEMA, "running": false, "state": state, "detail": detail})
}
