//! Widgets (`cmux.widget/1`): glanceable tiles an installed extension draws, placed by the person
//! on the New Tab page's grid and in the sidebar, as iPhone and Mac desktop widgets are. cmux
//! ships no widgets of its own (Leo, 2026-11-14: "we want them to be super supported but not
//! necessarily ship built versions outselevs (yet)"), and an extension never places itself:
//! the person does, with Add Widget or with the App Store's Install click, which places the
//! widget's default tile once (`place_installed_widget`; Leo, 2026-11-16: "if i click install
//! it means it works").
//!
//! What lives here, and so in Rust (language-boundaries.toml):
//!
//! - **The spec** of each widget, read from its manifest entry: the sizes it draws (Apple's
//!   families: small 1x1, medium 2x1, large 2x2 tiles), the size Add Widget places first, where
//!   it may go (`places`, both when absent; the sidebar takes small and medium only) and its
//!   refresh, raised to [`REFRESH_FLOOR_SECS`].
//! - **The layout**: the person's placed widgets per place, in order, each with its size and
//!   its own settings, kept in `<state>/apps-widgets-layout.json`. `apps.widgets.layout.edit`
//!   applies one edit (add, remove, resize, move, configure) from a person's gesture only, checks
//!   it against the widget's spec, and broadcasts `apps-widgets-changed` to every client, so every
//!   open New Tab page and sidebar redraws the same layout.
//! - **The mount context**: a page mounts a placed tile with `{place, size, instance}`; the
//!   context the render gets is built here (`surface: "widget"`, the tile's settings from the
//!   layout, the refresh it gets), and a size or place the widget does not offer is refused.
//! - **The refresh budget**: the host owns each widget mount's timer. Ticks fall on wall-clock
//!   boundaries of the widget's interval (a 60 s clock ticks on the minute), only while the page
//!   says the tile is shown (`apps.widgets.visible`); a hidden tile gets no tick and catches up with
//!   one when it shows. Outside [`SETTLE`] after a mount, a tick, a tap or a show, scene batches are
//!   coalesced to one per [`QUIET_INTERVAL`] (`budget.rs`); `apps.widgets.meters` reports the
//!   ticks, batches and held batches of each mount for the page's edit mode.
//!
//! Listing reads the catalog and the mirror only: no host starts until a page mounts a tile.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use cmux_app_host::ToHost;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::mirror::Origin;
use super::store::{bad_request, params, text};
use super::supervisor::{ApiError, HostState, Inner, MountKey, Out, Supervisor};
use super::timer::TimerId;
use crate::panic_free::RecoverPoison;

/// The interface a widget implements.
pub(super) const INTERFACE: &str = "cmux.widget/1";
/// The mount context's `surface` (`AppMountSurface.widget`).
pub(super) const SURFACE: &str = "widget";
/// The shortest interval a widget's clock ticks at, whatever its manifest asks.
pub(super) const REFRESH_FLOOR_SECS: u64 = 60;
/// The longest (one day).
pub(super) const REFRESH_MAX_SECS: u64 = 86_400;
/// Outside [`SETTLE`], a widget mount's scene batches go out at most this often.
pub(super) const QUIET_INTERVAL: Duration = Duration::from_secs(15);
/// After a mount, a tick, a tap or a show, a widget's batches go out at frame rate this long
/// (a fetch the tick started answers within it).
pub(super) const SETTLE: Duration = Duration::from_secs(5);
/// Let it crash: the first remount after a widget's render throws, doubled on each failure in a
/// row up to `RETRY_MAX`. A good render starts it over.
pub(super) const RETRY_FIRST: Duration = Duration::from_secs(1);
pub(super) const RETRY_MAX: Duration = Duration::from_secs(300);

/// How long to wait before mounting a widget again after its `failures`-th failed render in a row.
pub(super) fn retry_delay(failures: u32) -> Duration {
    let doublings = failures.saturating_sub(1).min(16);
    RETRY_FIRST.saturating_mul(1 << doublings).min(RETRY_MAX)
}

/// The layout document in the state directory.
const LAYOUT_FILE: &str = "apps-widgets-layout.json";
/// The most widgets one place holds.
pub(super) const MAX_PER_PLACE: usize = 32;
/// The largest settings object one tile keeps (serialized).
pub(super) const MAX_SETTINGS_BYTES: usize = 4 * 1024;
/// The longest instance id a page may mount with (a placed tile's, or a gallery preview's).
const MAX_INSTANCE_BYTES: usize = 128;
/// Layout edits replayed by idempotency key.
const MAX_KEYS: usize = 64;

/// A widget's size, as Apple's widget families.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum Size {
    Small,
    Medium,
    Large,
}

impl Size {
    pub(super) const ALL: [Size; 3] = [Size::Small, Size::Medium, Size::Large];

    pub(super) fn as_str(self) -> &'static str {
        match self {
            Size::Small => "small",
            Size::Medium => "medium",
            Size::Large => "large",
        }
    }

    pub(super) fn parse(name: &str) -> Option<Size> {
        Size::ALL.into_iter().find(|size| size.as_str() == name)
    }
}

/// Where a widget is placed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum Place {
    Newtab,
    Sidebar,
}

impl Place {
    pub(super) const ALL: [Place; 2] = [Place::Newtab, Place::Sidebar];

    pub(super) fn as_str(self) -> &'static str {
        match self {
            Place::Newtab => "newtab",
            Place::Sidebar => "sidebar",
        }
    }

    pub(super) fn parse(name: &str) -> Option<Place> {
        Place::ALL.into_iter().find(|place| place.as_str() == name)
    }

    /// Whether this place draws `size` (the sidebar is one column of small and medium tiles).
    pub(super) fn takes(self, size: Size) -> bool {
        self == Place::Newtab || size != Size::Large
    }
}

/// One widget's manifest entry, read once per listing or mount.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Spec {
    pub sizes: Vec<Size>,
    pub default_size: Size,
    /// Where it may go: the manifest's `places`, both when absent, without a place that takes
    /// none of its sizes.
    pub places: Vec<Place>,
    /// Its tick interval in seconds, raised to the floor; `None` without `refresh`.
    pub every: Option<u64>,
}

impl Spec {
    pub(super) fn from_entry(entry: &Value) -> Spec {
        let mut sizes: Vec<Size> = entry
            .pointer("/options/sizes")
            .and_then(Value::as_array)
            .map(|list| list.iter().filter_map(Value::as_str).filter_map(Size::parse).collect())
            .unwrap_or_default();
        sizes.dedup();
        if sizes.is_empty() {
            sizes.push(Size::Small);
        }
        let first = sizes.first().copied().unwrap_or(Size::Small);
        let default_size = entry
            .pointer("/options/defaultSize")
            .and_then(Value::as_str)
            .and_then(Size::parse)
            .filter(|size| sizes.contains(size))
            .unwrap_or(first);
        let named: Option<Vec<Place>> = entry
            .pointer("/options/places")
            .and_then(Value::as_array)
            .map(|list| list.iter().filter_map(Value::as_str).filter_map(Place::parse).collect());
        let places = named
            .filter(|list| !list.is_empty())
            .unwrap_or_else(|| Place::ALL.to_vec())
            .into_iter()
            .filter(|place| sizes.iter().any(|size| place.takes(*size)))
            .collect();
        let every = entry
            .pointer("/options/refresh/everySeconds")
            .and_then(Value::as_u64)
            .map(refresh_every);
        Spec { sizes, default_size, places, every }
    }

    /// The sizes `place` may show, in the widget's order.
    pub(super) fn sizes_in(&self, place: Place) -> Vec<Size> {
        self.sizes.iter().copied().filter(|size| place.takes(*size)).collect()
    }

    /// The size Add Widget places in `place`: the default when the place takes it, else the
    /// first size it takes.
    pub(super) fn default_in(&self, place: Place) -> Option<Size> {
        if place.takes(self.default_size) {
            return Some(self.default_size);
        }
        self.sizes_in(place).first().copied()
    }
}

/// The tick interval a manifest's `everySeconds` gets: at least the floor, at most a day.
pub(super) fn refresh_every(requested: u64) -> u64 {
    requested.clamp(REFRESH_FLOOR_SECS, REFRESH_MAX_SECS)
}

/// How long from `now_unix_ms` to the next wall-clock boundary of `every_secs` (the next whole
/// minute for 60 s, the next quarter hour for 900 s); a full interval when `now` is on one.
pub(super) fn next_tick_delay(now_unix_ms: u64, every_secs: u64) -> Duration {
    let period = every_secs.max(1).saturating_mul(1000);
    let into = now_unix_ms.checked_rem(period).unwrap_or(0);
    Duration::from_millis(period.saturating_sub(into))
}

// MARK: layout

/// One placed tile.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(super) struct Item {
    pub instance: String,
    pub app: String,
    pub size: Size,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub settings: Map<String, Value>,
}

/// The person's widget layout: each place's tiles, in order.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub(super) struct Layout {
    #[serde(default)]
    pub revision: u64,
    /// The next instance number (`w<next>`): ids are never reused.
    #[serde(default)]
    pub next: u64,
    #[serde(default)]
    pub newtab: Vec<Item>,
    #[serde(default)]
    pub sidebar: Vec<Item>,
}

impl Layout {
    pub(super) fn place(&self, place: Place) -> &Vec<Item> {
        match place {
            Place::Newtab => &self.newtab,
            Place::Sidebar => &self.sidebar,
        }
    }

    fn place_mut(&mut self, place: Place) -> &mut Vec<Item> {
        match place {
            Place::Newtab => &mut self.newtab,
            Place::Sidebar => &mut self.sidebar,
        }
    }

    /// The tile `instance`, in any place.
    pub(super) fn find(&self, instance: &str) -> Option<(Place, &Item)> {
        Place::ALL.into_iter().find_map(|place| {
            self.place(place)
                .iter()
                .find(|item| item.instance == instance)
                .map(|item| (place, item))
        })
    }
}

/// One layout edit (`apps.widgets.layout.edit {place, edit}`).
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "op", rename_all = "lowercase", deny_unknown_fields)]
pub(super) enum Edit {
    /// Places `app`'s widget at `size` (the widget's default for the place when absent),
    /// before the tile `before` (at the end when absent).
    Add {
        app: String,
        size: Option<String>,
        before: Option<String>,
    },
    Remove {
        instance: String,
    },
    Resize {
        instance: String,
        size: String,
    },
    /// Moves a tile before `before`, or to the end.
    Move {
        instance: String,
        before: Option<String>,
    },
    /// Replaces a tile's settings (an object of at most 4 KiB).
    Configure {
        instance: String,
        settings: Value,
    },
}

/// Applies `edit` to `layout`'s `place`. `spec` answers an app's widget spec when it is
/// installed, enabled and visible (an edit never places a widget the person cannot see).
pub(super) fn apply(
    layout: &mut Layout,
    place: Place,
    edit: Edit,
    spec: impl Fn(&str) -> Option<Spec>,
) -> Result<(), String> {
    let index_of =
        |items: &Vec<Item>, instance: &str| items.iter().position(|item| item.instance == instance);
    match edit {
        Edit::Add { app, size, before } => {
            let spec = spec(&app).ok_or_else(|| format!("{app} has no widget to place"))?;
            if !spec.places.contains(&place) {
                return Err(format!("{app}'s widget does not go in the {}", place.as_str()));
            }
            let size = match size {
                Some(name) => checked_size(&spec, place, &name)?,
                None => spec.default_in(place).ok_or_else(|| {
                    format!("{app}'s widget has no size for the {}", place.as_str())
                })?,
            };
            if layout.place(place).len() >= MAX_PER_PLACE {
                return Err(format!(
                    "the {} holds at most {MAX_PER_PLACE} widgets",
                    place.as_str()
                ));
            }
            layout.next = layout.next.saturating_add(1);
            let item =
                Item { instance: format!("w{}", layout.next), app, size, settings: Map::new() };
            let items = layout.place_mut(place);
            let at = match before.as_deref() {
                Some(target) => index_of(items, target)
                    .ok_or_else(|| format!("no widget {target} in the {}", place.as_str()))?,
                None => items.len(),
            };
            items.insert(at, item);
        }
        Edit::Remove { instance } => {
            let items = layout.place_mut(place);
            let at = index_of(items, &instance).ok_or_else(|| no_tile(&instance, place))?;
            items.remove(at);
        }
        Edit::Resize { instance, size } => {
            let app = layout
                .place(place)
                .iter()
                .find(|item| item.instance == instance)
                .map(|item| item.app.clone())
                .ok_or_else(|| no_tile(&instance, place))?;
            let spec = spec(&app).ok_or_else(|| format!("{app} has no widget to resize"))?;
            let size = checked_size(&spec, place, &size)?;
            if let Some(item) =
                layout.place_mut(place).iter_mut().find(|item| item.instance == instance)
            {
                item.size = size;
            }
        }
        Edit::Move { instance, before } => {
            let items = layout.place_mut(place);
            let from = index_of(items, &instance).ok_or_else(|| no_tile(&instance, place))?;
            if before.as_deref() == Some(instance.as_str()) {
                return Ok(());
            }
            let item = items.remove(from);
            let at = match before.as_deref() {
                Some(target) => match index_of(items, target) {
                    Some(at) => at,
                    None => {
                        items.insert(from, item);
                        return Err(format!("no widget {target} in the {}", place.as_str()));
                    }
                },
                None => items.len(),
            };
            items.insert(at, item);
        }
        Edit::Configure { instance, settings } => {
            let Value::Object(settings) = settings else {
                return Err("settings must be an object".into());
            };
            if serde_json::to_vec(&settings).map_or(usize::MAX, |raw| raw.len())
                > MAX_SETTINGS_BYTES
            {
                return Err(format!("settings are at most {MAX_SETTINGS_BYTES} bytes"));
            }
            let item = layout
                .place_mut(place)
                .iter_mut()
                .find(|item| item.instance == instance)
                .ok_or_else(|| no_tile(&instance, place))?;
            item.settings = settings;
        }
    }
    layout.revision = layout.revision.saturating_add(1);
    Ok(())
}

fn no_tile(instance: &str, place: Place) -> String {
    format!("no widget {instance} in the {}", place.as_str())
}

fn checked_size(spec: &Spec, place: Place, name: &str) -> Result<Size, String> {
    let size = Size::parse(name).ok_or_else(|| format!("{name} is not a widget size"))?;
    if !spec.sizes.contains(&size) {
        return Err(format!("the widget does not draw {name}"));
    }
    if !place.takes(size) {
        return Err(format!("the {} does not take {name} widgets", place.as_str()));
    }
    Ok(size)
}

// MARK: state

/// The supervisor's widget state: the layout (read from disk on first use) and the edits
/// replayed by key.
#[derive(Debug, Default)]
pub(super) struct WidgetState {
    layout: Option<Layout>,
    keys: VecDeque<(String, Value)>,
    /// The saved layout exists but could not be read (an I/O error, not a missing file): it is
    /// read again on next use, and no edit is saved over it meanwhile.
    unreadable: bool,
    /// Names each widget mount's timers (`WidgetMount::epoch`).
    pub next_epoch: u64,
}

/// A widget mount's clock and meter (on its `Mount`).
#[derive(Debug)]
pub(super) struct WidgetMount {
    pub place: Place,
    pub size: Size,
    pub instance: String,
    /// Its tick interval in seconds, `None` when it does not tick.
    pub every: Option<u64>,
    /// The page shows it (`apps.widgets.visible`); a new mount is shown.
    pub visible: bool,
    pub timer: Option<TimerId>,
    /// Names this mount's timers: a timer of an older mount under the same key does nothing.
    pub epoch: u64,
    /// When the clock last moved (the mount counts as one), Unix ms.
    pub last_tick_ms: u64,
    pub ticks: u64,
    /// Renders that threw since the last good one (let it crash: the page keeps the last good
    /// scene, marked stale, and the mount is tried again after `retry_delay`).
    pub failures: u32,
    /// The pending remount after a failure.
    pub retry: Option<TimerId>,
    /// A remount came due while the tile was hidden: it runs when the page shows it again.
    pub retry_due: bool,
    /// The wall-clock boundary (Unix ms) the armed tick is for. A timer is armed for at most
    /// [`MAX_ARM`] at a time and checks the wall clock when it fires, so a sleep or a clock change
    /// never delays a tick by more than that.
    pub due_ms: u64,
}

/// The longest a widget's tick timer is armed for before it looks at the wall clock again.
pub(super) const MAX_ARM: Duration = Duration::from_secs(60);

/// The mount context a page's `{place, size, instance}` gets for a widget with `spec`, or why
/// it is refused. `settings` are the tile's own from the layout (empty for a gallery preview).
pub(super) fn mount_context(
    app: &str,
    spec: &Spec,
    asked: &Value,
    layout: &Layout,
) -> Result<(Value, WidgetMount), ApiError> {
    let place = asked
        .get("place")
        .and_then(Value::as_str)
        .and_then(Place::parse)
        .ok_or_else(|| bad_request("a widget mounts with place newtab or sidebar"))?;
    if !spec.places.contains(&place) {
        return Err(ApiError::new(
            "apps.widgets.place",
            format!("the widget does not go in the {}", place.as_str()),
        ));
    }
    let size = match asked.get("size").and_then(Value::as_str) {
        Some(name) => checked_size(spec, place, name)
            .map_err(|message| ApiError::new("apps.widgets.size", message))?,
        None => spec.default_in(place).ok_or_else(|| bad_request("no size for this place"))?,
    };
    let instance = asked.get("instance").and_then(Value::as_str).unwrap_or_default();
    if instance.is_empty() || instance.len() > MAX_INSTANCE_BYTES {
        return Err(bad_request("a widget mounts with an instance id of 1 to 128 bytes"));
    }
    // Only this app's own tile in this place lends its settings: a page cannot mount one widget
    // with another's instance id and read that tile's settings.
    let settings = layout
        .find(instance)
        .filter(|(at, item)| *at == place && item.app == app)
        .map(|(_, item)| Value::Object(item.settings.clone()))
        .unwrap_or_else(|| json!({}));
    // The page's locale and time zone (it has Intl and the system's settings; the sandbox has
    // neither), so a widget names the local zone and formats for the person. A missing or
    // malformed one falls back: English, and the zone this daemon runs in.
    let locale = asked
        .get("locale")
        .and_then(Value::as_str)
        .filter(|tag| is_word(tag, 35, |c| c == '-'))
        .unwrap_or("en");
    let time_zone = asked
        .get("timeZone")
        .and_then(Value::as_str)
        .filter(|zone| is_zone_name(zone))
        .map_or_else(local_zone, str::to_string);
    let mut context = json!({
        "surface": SURFACE,
        "place": place.as_str(),
        "size": size.as_str(),
        "instance": instance,
        "settings": settings,
        "refresh": spec.every.map(|every| json!({ "everySeconds": every })),
        "locale": locale,
        "timeZone": time_zone,
    });
    if asked.get("preview").and_then(Value::as_bool) == Some(true)
        && let Some(object) = context.as_object_mut()
    {
        object.insert("preview".into(), Value::Bool(true));
    }
    let widget = WidgetMount {
        place,
        size,
        instance: instance.to_string(),
        every: spec.every,
        visible: true,
        timer: None,
        epoch: 0,
        last_tick_ms: super::supervisor::now_ms(),
        ticks: 0,
        failures: 0,
        retry: None,
        retry_due: false,
        due_ms: 0,
    };
    Ok((context, widget))
}

/// `text` is 1 to `max` bytes of ASCII letters, digits and the characters `extra` allows.
fn is_word(text: &str, max: usize, extra: impl Fn(char) -> bool) -> bool {
    !text.is_empty()
        && text.len() <= max
        && text.chars().all(|c| c.is_ascii_alphanumeric() || extra(c))
}

/// An IANA zone name's shape (`Europe/Paris`, `America/Argentina/Buenos_Aires`, `Etc/GMT+9`).
fn is_zone_name(zone: &str) -> bool {
    is_word(zone, 64, |c| matches!(c, '/' | '_' | '-' | '+'))
        && !zone.starts_with('/')
        && !zone.split('/').any(|part| part.is_empty() || part == "..")
}

/// The IANA name of the zone this daemon runs in: `TZ`, else where `/etc/localtime` points
/// (`.../zoneinfo/Europe/Paris`), else `UTC`.
fn local_zone() -> String {
    let from_env = std::env::var("TZ").ok().map(|tz| tz.trim_start_matches(':').to_string());
    let from_link = || {
        let target = std::fs::read_link("/etc/localtime").ok()?;
        let target = target.to_str()?;
        Some(target.split_once("zoneinfo/")?.1.to_string())
    };
    from_env
        .filter(|zone| is_zone_name(zone))
        .or_else(|| from_link().filter(|zone| is_zone_name(zone)))
        .unwrap_or_else(|| "UTC".to_string())
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct ListParams {
    place: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct EditParams {
    place: String,
    edit: Edit,
    idempotency_key: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct VisibleParams {
    mount_id: String,
    visible: bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct EmptyParams {}

impl Supervisor {
    /// One widget op, or `None` when `op` is not one.
    pub(super) fn widget_call(
        &self,
        client: u64,
        op: &str,
        args: Value,
        origin: Origin,
    ) -> Option<Result<Value, ApiError>> {
        Some(match op {
            "apps.widgets.list" => params::<ListParams>(args).and_then(|p| self.widgets_list(p)),
            "apps.widgets.layout.edit" => {
                params::<EditParams>(args).and_then(|p| self.widgets_edit(p, origin))
            }
            "apps.widgets.visible" => params::<VisibleParams>(args)
                .and_then(|p| self.widget_visible(client, &p.mount_id, p.visible)),
            "apps.widgets.meters" => {
                params::<EmptyParams>(args).map(|_| self.widget_meters(client))
            }
            _ => return None,
        })
    }

    /// Each installed, enabled and visible app's widget spec, by app id.
    pub(super) fn widget_spec_locked(inner: &Inner, app: &str) -> Option<Spec> {
        let record = inner.mirror.apps.get(app)?;
        if !(record.installed && record.enabled && !record.hidden) {
            return None;
        }
        let package = inner.catalog.packages.get(app)?;
        package.export_for(INTERFACE)?;
        let entry = package.manifest.get("implements")?.get(INTERFACE)?;
        Some(Spec::from_entry(entry))
    }

    /// The layout, read from the state directory on first use (empty when none was saved or
    /// the file does not read).
    pub(super) fn widget_layout_locked<'a>(&self, inner: &'a mut Inner) -> &'a mut Layout {
        let state = &mut inner.widgets;
        if state.layout.is_none() || state.unreadable {
            let read = match &self.config.state_dir {
                Some(dir) => read_layout(dir),
                None => Ok(Layout::default()),
            };
            state.unreadable = read.is_err();
            state.layout = Some(read.unwrap_or_default());
        }
        state.layout.get_or_insert_with(Layout::default)
    }

    /// `apps.widgets.list {place?}`: every widget the person can place (in `place` when named),
    /// and the layout, with tiles of apps no longer shown left out.
    fn widgets_list(&self, p: ListParams) -> Result<Value, ApiError> {
        let wanted = match p.place.as_deref() {
            Some(name) => {
                Some(Place::parse(name).ok_or_else(|| bad_request("place is newtab or sidebar"))?)
            }
            None => None,
        };
        let mut inner = self.inner.lock().recover_poison();
        let mut widgets = Vec::new();
        for (app, package) in &inner.catalog.packages {
            let Some(spec) = Self::widget_spec_locked(&inner, app) else { continue };
            if wanted.is_some_and(|place| !spec.places.contains(&place)) {
                continue;
            }
            let Some(entry) =
                package.manifest.pointer("/implements").and_then(|i| i.get(INTERFACE))
            else {
                continue;
            };
            let mut row = json!({
                "app": app,
                "title": entry.get("title").map_or_else(|| text(package.manifest.get("name").unwrap_or(&Value::Null)), text),
                "sizes": spec.sizes.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
                "defaultSize": spec.default_size.as_str(),
                "places": spec.places.iter().map(|p| p.as_str()).collect::<Vec<_>>(),
                "refresh": spec.every.map(|every| json!({ "everySeconds": every })),
            });
            if let Some(object) = row.as_object_mut() {
                if let Some(symbol) = entry.get("symbol").and_then(Value::as_str) {
                    object.insert("symbol".into(), Value::String(symbol.into()));
                }
                let description = entry.get("description").map(text).unwrap_or_else(|| {
                    text(package.manifest.get("description").unwrap_or(&Value::Null))
                });
                if !description.is_empty() {
                    object.insert("description".into(), Value::String(description));
                }
            }
            widgets.push(row);
        }
        let shown: std::collections::BTreeSet<String> = widgets
            .iter()
            .filter_map(|row| row.get("app").and_then(Value::as_str).map(str::to_string))
            .collect();
        let layout = self.widget_layout_locked(&mut inner).clone();
        Ok(json!({ "widgets": widgets, "layout": layout_json(&layout, &shown, wanted) }))
    }

    /// `apps.widgets.layout.edit`: one edit from the person's gesture, saved, then broadcast.
    fn widgets_edit(&self, p: EditParams, origin: Origin) -> Result<Value, ApiError> {
        if origin != Origin::User {
            return Err(ApiError::new("apps.origin", "only a person can change where widgets are"));
        }
        if p.idempotency_key.is_empty() || p.idempotency_key.len() > 256 {
            return Err(bad_request("idempotency_key is 1 to 256 bytes"));
        }
        let place =
            Place::parse(&p.place).ok_or_else(|| bad_request("place is newtab or sidebar"))?;
        self.edit_layout(place, p.edit, Some(p.idempotency_key))
    }

    /// The person's Install of an app that draws a widget places its tile, at the widget's
    /// default size, at the end of the New Tab page (the sidebar when the widget goes only
    /// there), unless a tile of it is already placed. The person placed it with the Install
    /// click; the app never places itself. Leo, 2026-11-16: "i click install they dont do
    /// anything / if i click install it means it works". `None` when the app has no widget or
    /// one is already placed; a layout that cannot be written leaves the install as it is.
    pub(super) fn place_installed_widget(&self, app: &str) -> Option<Value> {
        let place = {
            let mut inner = self.inner.lock().recover_poison();
            let spec = Self::widget_spec_locked(&inner, app)?;
            let layout = self.widget_layout_locked(&mut inner);
            if Place::ALL.into_iter().any(|place| layout.place(place).iter().any(|i| i.app == app))
            {
                return None;
            }
            [Place::Newtab, Place::Sidebar]
                .into_iter()
                .find(|place| spec.places.contains(place) && spec.default_in(*place).is_some())?
        };
        let edit = Edit::Add { app: app.to_string(), size: None, before: None };
        match self.edit_layout(place, edit, None) {
            Ok(_) => Some(json!({ "place": place.as_str() })),
            Err(error) => {
                eprintln!(
                    "cmux-tui: install of {app} could not place its widget: {}",
                    error.message
                );
                None
            }
        }
    }

    /// Applies one layout edit under the supervisor lock, saves it, then broadcasts it. With a
    /// key, a repeat of the same key answers the first result without a second edit.
    fn edit_layout(
        &self,
        place: Place,
        edit: Edit,
        idempotency_key: Option<String>,
    ) -> Result<Value, ApiError> {
        let (result, revision) = {
            let mut inner = self.inner.lock().recover_poison();
            if let Some(key) = &idempotency_key
                && let Some((_, value)) = inner.widgets.keys.iter().find(|(k, _)| k == key)
            {
                return Ok(value.clone());
            }
            let specs: std::collections::HashMap<String, Spec> = inner
                .catalog
                .packages
                .keys()
                .filter_map(|app| Some((app.clone(), Self::widget_spec_locked(&inner, app)?)))
                .collect();
            let shown = specs.keys().cloned().collect();
            let mut next = self.widget_layout_locked(&mut inner).clone();
            if inner.widgets.unreadable {
                return Err(ApiError::new(
                    "operation.failed",
                    "the saved widget layout could not be read; nothing was changed",
                ));
            }
            apply(&mut next, place, edit, |app| specs.get(app).cloned())
                .map_err(|message| ApiError::new("apps.widgets.edit", message))?;
            // Under the supervisor lock: two pages' edits land one after the other.
            if let Some(dir) = &self.config.state_dir {
                write_durably(dir, LAYOUT_FILE, &next)
                    .map_err(|e| ApiError::new("operation.failed", e.to_string()))?;
            }
            let result = json!({ "layout": layout_json(&next, &shown, None) });
            *self.widget_layout_locked(&mut inner) = next.clone();
            if let Some(key) = idempotency_key {
                if inner.widgets.keys.len() >= MAX_KEYS {
                    inner.widgets.keys.pop_front();
                }
                inner.widgets.keys.push_back((key, result.clone()));
            }
            (result, next.revision)
        };
        self.emit(vec![Out::Broadcast(json!({
            "event": "apps-widgets-changed",
            "revision": revision,
            "place": place.as_str(),
        }))]);
        Ok(result)
    }

    /// `apps.widgets.visible`: the page shows or hides one of its widget mounts. A hidden mount
    /// gets no tick; one shown again catches up with a tick when it missed one.
    fn widget_visible(
        &self,
        client: u64,
        mount_id: &str,
        visible: bool,
    ) -> Result<Value, ApiError> {
        let key = MountKey { client, mount_id: mount_id.to_string() };
        let mut inner = self.inner.lock().recover_poison();
        let now = Instant::now();
        let now_ms = super::supervisor::now_ms();
        let mount = inner
            .mounts
            .get_mut(&key)
            .ok_or_else(|| ApiError::new("apps.mount.unknown", "no such mount"))?;
        let Some(widget) = mount.widget.as_mut() else {
            return Err(ApiError::new("apps.widgets.mount", "the mount is not a widget"));
        };
        if widget.visible == visible {
            return Ok(json!({}));
        }
        widget.visible = visible;
        if let Some(timer) = widget.timer.take() {
            self.timers.cancel(timer);
        }
        if !visible {
            // The signals this mount watches sleep while nobody sees it (`signals_cache.rs`).
            self.signals_mount_visible_locked(&inner, &key, false);
            return Ok(json!({}));
        }
        mount.budget.settle(now, SETTLE);
        let retry_due = std::mem::take(&mut widget.retry_due);
        let missed = widget.every.is_some_and(|every| {
            now_ms.saturating_sub(widget.last_tick_ms) >= every.saturating_mul(1000)
        });
        self.signals_mount_visible_locked(&inner, &key, true);
        if retry_due {
            // The remount it missed while hidden runs now; its fresh mount starts a fresh clock.
            let outs = self.widget_remount_locked(&mut inner, &key);
            self.schedule_tick_locked(&mut inner, &key);
            drop(inner);
            self.emit(outs);
            return Ok(json!({}));
        }
        if missed {
            self.send_tick_locked(&mut inner, &key, now_ms);
        }
        self.schedule_tick_locked(&mut inner, &key);
        Ok(json!({}))
    }

    /// `apps.widgets.meters`: this client's widget mounts with their clock and budget counts.
    fn widget_meters(&self, client: u64) -> Value {
        let inner = self.inner.lock().recover_poison();
        let mut meters: Vec<Value> = inner
            .mounts
            .iter()
            .filter(|(key, _)| key.client == client)
            .filter_map(|(key, mount)| {
                let widget = mount.widget.as_ref()?;
                Some(json!({
                    "mount_id": key.mount_id,
                    "app": mount.host.app,
                    "instance": widget.instance,
                    "place": widget.place.as_str(),
                    "size": widget.size.as_str(),
                    "everySeconds": widget.every,
                    "visible": widget.visible,
                    "ticks": widget.ticks,
                    "failures": widget.failures,
                    "batches": mount.budget.batches_in,
                    "sent": mount.budget.batches_out,
                    "held": mount.budget.held,
                    "step": mount.budget.step().as_str(),
                }))
            })
            .collect();
        let id = |meter: &Value| meter.get("mount_id").and_then(Value::as_str).map(str::to_owned);
        meters.sort_by_key(id);
        json!({ "meters": meters })
    }

    /// Arms `key`'s next tick on its interval's wall-clock boundary, when it ticks and is shown.
    pub(super) fn schedule_tick_locked(&self, inner: &mut Inner, key: &MountKey) {
        let Some(widget) = inner.mounts.get_mut(key).and_then(|m| m.widget.as_mut()) else {
            return;
        };
        if let Some(timer) = widget.timer.take() {
            self.timers.cancel(timer);
        }
        let Some(every) = widget.every.filter(|_| widget.visible) else { return };
        let now_ms = super::supervisor::now_ms();
        // A boundary not yet ticked for stays the target (one passed while hidden ticks at once).
        // A clock set back leaves the boundary too far ahead: aim at the next one from now.
        if widget.due_ms <= widget.last_tick_ms
            || widget.due_ms > now_ms.saturating_add(every.saturating_mul(1000))
        {
            widget.due_ms = now_ms.saturating_add(as_ms(next_tick_delay(now_ms, every)));
        }
        let delay = Duration::from_millis(widget.due_ms.saturating_sub(now_ms)).min(MAX_ARM);
        let me = self.me.clone();
        let timer_key = key.clone();
        let epoch = widget.epoch;
        widget.timer = Some(self.timers.schedule(delay, move || {
            if let Some(me) = me.upgrade() {
                me.tick_fired(&timer_key, epoch);
            }
        }));
    }

    fn tick_fired(&self, key: &MountKey, epoch: u64) {
        let mut inner = self.inner.lock().recover_poison();
        let Some(widget) = inner.mounts.get_mut(key).and_then(|m| m.widget.as_mut()) else {
            return;
        };
        if widget.epoch != epoch || !widget.visible {
            return;
        }
        widget.timer = None;
        let now_ms = super::supervisor::now_ms();
        // Armed for at most MAX_ARM: until the wall clock reaches the boundary, only re-arm.
        if now_ms >= widget.due_ms {
            self.send_tick_locked(&mut inner, key, now_ms);
        }
        self.schedule_tick_locked(&mut inner, key);
    }

    /// Moves `key`'s clock to `now_ms` in its host, when the host runs (a starting or restarting
    /// host mounts it fresh, with a fresh clock).
    fn send_tick_locked(&self, inner: &mut Inner, key: &MountKey, now_ms: u64) {
        let Some(mount) = inner.mounts.get_mut(key) else { return };
        let Some(widget) = mount.widget.as_mut() else { return };
        widget.last_tick_ms = now_ms;
        widget.ticks = widget.ticks.saturating_add(1);
        mount.budget.settle(Instant::now(), SETTLE);
        let host = mount.host.clone();
        let running = inner
            .hosts
            .get(&host)
            .filter(|h| matches!(h.state, HostState::Starting | HostState::Running))
            .and_then(|h| h.process.clone());
        if let Some(process) = running {
            process.send(&ToHost::Tick { mount: key.wire(), now_ms });
        }
    }

    /// Let it crash: `key`'s render threw. The mount stays (the page keeps its last good scene and
    /// marks it stale, never a blank tile), and it is mounted again after `retry_delay`.
    pub(super) fn widget_mount_failed_locked(
        &self,
        inner: &mut Inner,
        key: &MountKey,
        reason: String,
    ) -> Vec<Out> {
        let Some(widget) = inner.mounts.get_mut(key).and_then(|m| m.widget.as_mut()) else {
            return vec![];
        };
        widget.failures = widget.failures.saturating_add(1);
        let delay = retry_delay(widget.failures);
        if let Some(timer) = widget.retry.take() {
            self.timers.cancel(timer);
        }
        let me = self.me.clone();
        let timer_key = key.clone();
        let epoch = widget.epoch;
        widget.retry = Some(self.timers.schedule(delay, move || {
            if let Some(me) = me.upgrade() {
                me.widget_retry_fired(&timer_key, epoch);
            }
        }));
        vec![Out::Client(
            key.client,
            json!({
                "event": "apps-widget-health",
                "mount_id": key.mount_id,
                "stale": true,
                "reason": reason,
                "failures": widget.failures,
                "retry_ms": u64::try_from(delay.as_millis()).unwrap_or(u64::MAX),
            }),
        )]
    }

    /// A widget's render answered: a stale one is fresh again and its backoff starts over.
    pub(super) fn widget_mount_good_locked(&self, inner: &mut Inner, key: &MountKey) -> Vec<Out> {
        let Some(widget) = inner.mounts.get_mut(key).and_then(|m| m.widget.as_mut()) else {
            return vec![];
        };
        if let Some(timer) = widget.retry.take() {
            self.timers.cancel(timer);
        }
        widget.retry_due = false;
        if widget.failures == 0 {
            return vec![];
        }
        widget.failures = 0;
        vec![Out::Client(
            key.client,
            json!({ "event": "apps-widget-health", "mount_id": key.mount_id, "stale": false }),
        )]
    }

    fn widget_retry_fired(&self, key: &MountKey, epoch: u64) {
        let outs = {
            let mut inner = self.inner.lock().recover_poison();
            let Some(mount) = inner.mounts.get_mut(key) else { return };
            let Some(widget) = mount.widget.as_mut() else { return };
            if widget.epoch != epoch {
                return;
            }
            widget.retry = None;
            // A hidden tile is not remounted (it would spend a render nobody sees): it is when shown.
            if !widget.visible {
                widget.retry_due = true;
                return;
            }
            self.widget_remount_locked(&mut inner, key)
        };
        self.emit(outs);
    }

    /// Mounts `key` again in its host: its first batch replaces the stale tree the page kept (and
    /// any ops held for it), at frame rate.
    fn widget_remount_locked(&self, inner: &mut Inner, key: &MountKey) -> Vec<Out> {
        let Some(mount) = inner.mounts.get_mut(key) else { return vec![] };
        mount.reset = true;
        mount.budget.clear_pending();
        mount.budget.settle(Instant::now(), SETTLE);
        let (host, export, ctx) = (mount.host.clone(), mount.export.clone(), mount.context.clone());
        let wire = key.wire();
        self.revive_host_locked(inner, &host, |process| {
            process.send(&ToHost::Mount { mount: wire, export, ctx });
        })
    }

    /// Cancels a widget mount's timers (its tick and a pending remount), when it goes away.
    pub(super) fn cancel_widget_timers(&self, widget: Option<&WidgetMount>) {
        for timer in widget.into_iter().flat_map(|w| [w.timer, w.retry]).flatten() {
            self.timers.cancel(timer);
        }
    }
}

#[cfg(test)]
impl Supervisor {
    /// Test hook: the tick a widget mount's timer would send, now.
    pub(super) fn widget_tick_now(&self, client: u64, mount_id: &str) {
        let key = MountKey { client, mount_id: mount_id.to_string() };
        let mut inner = self.inner.lock().recover_poison();
        self.send_tick_locked(&mut inner, &key, super::supervisor::now_ms());
    }

    /// Test hook: whether a widget mount has its next tick armed (`None`: no such widget).
    pub(super) fn widget_armed(&self, client: u64, mount_id: &str) -> Option<bool> {
        let key = MountKey { client, mount_id: mount_id.to_string() };
        let inner = self.inner.lock().recover_poison();
        inner.mounts.get(&key)?.widget.as_ref().map(|w| w.timer.is_some())
    }

    /// Test hook: whether a hidden widget mount owes a remount (`None`: no such widget).
    pub(super) fn widget_retry_due(&self, client: u64, mount_id: &str) -> Option<bool> {
        let key = MountKey { client, mount_id: mount_id.to_string() };
        let inner = self.inner.lock().recover_poison();
        inner.mounts.get(&key)?.widget.as_ref().map(|w| w.retry_due)
    }
}

/// The layout as pages read it: `{revision, newtab: [...], sidebar: [...]}` (only `place` when
/// named), without tiles of apps that are not shown (`shown`).
fn layout_json(
    layout: &Layout,
    shown: &std::collections::BTreeSet<String>,
    only: Option<Place>,
) -> Value {
    let mut out = Map::new();
    out.insert("revision".into(), json!(layout.revision));
    for place in Place::ALL {
        if only.is_some_and(|only| only != place) {
            continue;
        }
        let items: Vec<&Item> =
            layout.place(place).iter().filter(|item| shown.contains(&item.app)).collect();
        out.insert(place.as_str().into(), json!(items));
    }
    Value::Object(out)
}

/// Writes `value` as `name` in `dir` durably: temp file, fsync, rename.
fn write_durably(dir: &std::path::Path, name: &str, value: &impl Serialize) -> std::io::Result<()> {
    use std::io::Write as _;
    std::fs::create_dir_all(dir)?;
    let temp = dir.join(format!("{name}.tmp"));
    let body = serde_json::to_vec_pretty(value).map_err(std::io::Error::other)?;
    let mut file = std::fs::File::create(&temp)?;
    file.write_all(&body)?;
    file.sync_all()?;
    std::fs::rename(&temp, dir.join(name))?;
    // The rename survives a crash only once the directory is synced. The file is already in
    // place, so a failed sync is logged, not an error the in-memory copy would disagree with.
    if let Err(error) = std::fs::File::open(dir).and_then(|d| d.sync_all()) {
        eprintln!("cmux-tui: sync of {}: {error}", dir.display());
    }
    Ok(())
}

fn as_ms(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

/// The saved layout in `dir` (empty when none was saved). A file that does not parse as a layout
/// is renamed to `<name>.bad-<unix ms>` and logged, never overwritten by the next edit; one that
/// cannot be read (permissions, I/O) is an error, so nothing is saved over it.
fn read_layout(dir: &std::path::Path) -> Result<Layout, std::io::Error> {
    let path = dir.join(LAYOUT_FILE);
    let raw = match std::fs::read(&path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Layout::default()),
        Err(error) => {
            eprintln!("cmux-tui: widget layout {} does not read: {error}", path.display());
            return Err(error);
        }
    };
    Ok(match serde_json::from_slice::<Layout>(&raw) {
        Ok(layout) => layout,
        Err(error) => {
            let aside = dir.join(format!("{LAYOUT_FILE}.bad-{}", super::supervisor::now_ms()));
            let kept = std::fs::rename(&path, &aside);
            eprintln!(
                "cmux-tui: widget layout {} does not read ({error}); kept as {} ({kept:?}), starting empty",
                path.display(),
                aside.display()
            );
            Layout::default()
        }
    })
}

#[cfg(test)]
#[path = "widgets_tests.rs"]
mod tests;
