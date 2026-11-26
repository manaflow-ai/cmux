//! What the running share host knows, shared by its hub link, the app's device channel and
//! `_acpmux/share_host_status`: the hub client (its device), the link's state, the app channels
//! subscribed to pushes, the hub's device list, and what the app told the channel.

use super::{NotRunning, records};
use cmux_hub_host::hub::Hub;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
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
    /// App channels that asked `device.watch`: each hears `online` as the daemon comes online.
    watchers: Mutex<Vec<UnboundedSender<String>>>,
    pub app: Mutex<AppNotes>,
    /// The hub's devices: id -> platform.
    devices: Mutex<HashMap<String, String>>,
    /// The hub's other devices as screens, from the last `GET /v1/devices`; None before a read.
    screens: Mutex<Option<Vec<HubScreen>>>,
    /// The share approval nonces this daemon took (`approval.rs`): each tap admits once.
    seen_approvals: Mutex<HashSet<String>>,
}

/// One of the device hub's records other than this device's: a machine's screen host.
#[derive(Debug, Clone)]
struct HubScreen {
    /// The hub's device id: what a viewer opens (`macScreen.open --device`).
    id: String,
    name: String,
    platform: String,
    online: bool,
    /// The hub's `macScreenShared`: the screen host turned sharing on (a Linux one does as it
    /// joins).
    shared: bool,
    /// The hub's `lastSeenAt`, else `createdAt`: which of two equal records is newer.
    seen: Option<f64>,
}

impl HubScreen {
    /// Whether `self` is the better record of one machine: the app's own rule
    /// (`cmux_cloud_config::device_list`'s `better`): online, then sharing, then seen last. So
    /// `peers` and `macScreen.open --device <name>` name the same record.
    fn better(&self, other: &Self) -> bool {
        let rank = |s: &Self| (s.online, s.shared);
        if rank(self) != rank(other) {
            return rank(self) > rank(other);
        }
        self.seen.unwrap_or(f64::MIN) > other.seen.unwrap_or(f64::MIN)
    }
}

/// The name a hub record and a mesh host have in common: the first DNS label, lowercased (the
/// mesh lists `pairing::machine_name`, the host label; a screen host registers the join's name or
/// the kernel host name).
fn host_key(name: &str) -> String {
    name.trim().split('.').next().unwrap_or_default().to_ascii_lowercase()
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

static RUNNING: OnceLock<Arc<Shared>> = OnceLock::new();
static NOT_RUNNING: Mutex<Option<NotRunning>> = Mutex::new(None);
/// On Linux: how setting up cmux-rd's host went (`super::linux::status_json`).
static LINUX: Mutex<Option<Value>> = Mutex::new(None);

/// Records why this daemon runs no share host.
pub(crate) fn not_running(why: NotRunning) {
    *lock(&NOT_RUNNING) = Some(why);
}

/// Records the state of this Linux machine's cmux-rd host.
pub(crate) fn linux(status: Value) {
    *lock(&LINUX) = Some(status);
}

impl Shared {
    pub(crate) fn new(home: PathBuf, hub: Hub) -> Arc<Self> {
        Arc::new(Self {
            home,
            hub: Mutex::new(Arc::new(hub)),
            link: Mutex::new(Link { state: "starting", ..Link::default() }),
            subscribers: Mutex::new(Vec::new()),
            watchers: Mutex::new(Vec::new()),
            app: Mutex::new(AppNotes::default()),
            devices: Mutex::new(HashMap::new()),
            screens: Mutex::new(None),
            seen_approvals: Mutex::new(HashSet::new()),
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

    /// `{"event":"online","id":..,"user_id":..}` while the link is online signed in: the device the
    /// daemon holds now and its account, so an app that took another identity (it asked before
    /// the daemon signed in, or before it registered a new device) follows this one.
    pub(crate) fn online_event(&self) -> Option<String> {
        if self.link().state != "online" {
            return None;
        }
        let hub = self.hub();
        let user = hub.user_id()?;
        Some(json!({"event": "online", "id": hub.device.id, "user_id": user}).to_string())
    }

    /// A new app channel that hears [`Shared::online_event`]: now when the link is online, and
    /// each time it comes online again.
    pub(crate) fn watch(&self, sender: UnboundedSender<String>) {
        if let Some(line) = self.online_event()
            && sender.send(line).is_err()
        {
            return;
        }
        lock(&self.watchers).push(sender);
    }

    /// Tells every watching app channel the link is online (as [`Shared::online_event`]).
    pub(crate) fn announce_online(&self) {
        if let Some(line) = self.online_event() {
            lock(&self.watchers).retain(|s| s.send(line.clone()).is_ok());
        }
    }

    pub(crate) fn set_devices(&self, devices: &Value) {
        let mut map = HashMap::new();
        let mut screens = Vec::new();
        let own = self.hub().device.id.clone();
        for device in devices.get("devices").and_then(Value::as_array).into_iter().flatten() {
            let field = |k: &str| device.get(k).and_then(Value::as_str).map(str::to_owned);
            let flag = |k: &str| device.get(k).and_then(Value::as_bool);
            if let (Some(id), Some(platform)) = (field("id"), field("platform")) {
                if id == own {
                    let shared = flag("macScreenShared");
                    self.update_link(|link| link.sharing = shared.or(link.sharing));
                } else if let Some(name) = field("name").filter(|n| !n.trim().is_empty()) {
                    screens.push(HubScreen {
                        id: id.clone(),
                        name,
                        platform: platform.clone(),
                        online: flag("online").unwrap_or(false),
                        shared: flag("macScreenShared").unwrap_or(false),
                        seen: ["lastSeenAt", "createdAt"]
                            .iter()
                            .find_map(|k| device.get(*k).and_then(Value::as_f64)),
                    });
                }
                map.insert(id, platform);
            }
        }
        *lock(&self.devices) = map;
        *lock(&self.screens) = Some(screens);
    }

    /// What the device hub says of the screen of machine `host` (a mesh host, `peers`'
    /// `deviceHub`): `{"listed": false}` when no record has its name, else the platform and
    /// whether its screen host shares (a record online first, then one sharing, then the one
    /// seen last, as the app picks). None before the hub's device list was read: nothing is known.
    pub(crate) fn device_hub_of(&self, host: &str) -> Option<Value> {
        let screens = lock(&self.screens);
        let key = host_key(host);
        let best = screens
            .as_ref()?
            .iter()
            .filter(|s| !key.is_empty() && host_key(&s.name) == key)
            .fold(None::<&HubScreen>, |best, s| match best {
                Some(b) if !s.better(b) => Some(b),
                _ => Some(s),
            });
        Some(match best {
            Some(s) => json!({"listed": true, "id": s.id, "platform": s.platform,
                "online": s.online, "screenShared": s.shared}),
            None => json!({"listed": false}),
        })
    }

    /// Runs `decide` with the taken approval nonces, one approval at a time.
    pub(crate) fn with_seen_approvals<T>(
        &self,
        decide: impl FnOnce(&mut HashSet<String>) -> T,
    ) -> T {
        decide(&mut lock(&self.seen_approvals))
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

/// [`Shared::device_hub_of`] of this daemon's running share host; None when none runs.
pub(crate) fn device_hub_of(host: &str) -> Option<Value> {
    RUNNING.get()?.device_hub_of(host)
}

/// `share-host status` in this daemon: the running host's, or why it does not run.
pub(crate) fn status_now() -> Value {
    if let Some(shared) = RUNNING.get() {
        return shared.status_json();
    }
    if let Some(status) = lock(&LINUX).clone() {
        return status;
    }
    let why = lock(&NOT_RUNNING).clone();
    not_running_json(why.as_ref(), cfg!(any(target_os = "macos", target_os = "linux")))
}

/// The status of a share host that does not run, and why. `supported`: this daemon's system has
/// a share host (macOS, Linux).
pub(crate) fn not_running_json(why: Option<&NotRunning>, supported: bool) -> Value {
    let (state, detail) = match why {
        Some(why) => (why.code, why.detail.clone()),
        None if !supported => ("unsupported", "the share host runs on macOS and Linux".to_owned()),
        None => ("not_started", "this daemon did not start the share host".to_owned()),
    };
    json!({"schema": SCHEMA, "running": false, "state": state, "detail": detail})
}
