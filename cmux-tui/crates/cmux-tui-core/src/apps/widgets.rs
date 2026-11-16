//! Widgets (`cmux.widget/1`): glanceable tiles an installed extension draws, placed by the person
//! on the New Tab page's grid and in the sidebar, as iPhone and Mac desktop widgets are. cmux
//! ships no widgets of its own (Leo, 2026-11-14: "we want them to be super supported but not
//! necessarily ship built versions outselevs (yet)"), and an extension never places itself.
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

    /// Its tiles on the grid, (columns, rows).
    pub(super) fn tiles(self) -> (u8, u8) {
        match self {
            Size::Small => (1, 1),
            Size::Medium => (2, 1),
            Size::Large => (2, 2),
        }
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
}

/// The mount context a page's `{place, size, instance}` gets for a widget with `spec`, or why
/// it is refused. `settings` are the tile's own from the layout (empty for a gallery preview).
pub(super) fn mount_context(
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
    let settings = layout
        .find(instance)
        .map(|(_, item)| Value::Object(item.settings.clone()))
        .unwrap_or_else(|| json!({}));
    let mut context = json!({
        "surface": SURFACE,
        "place": place.as_str(),
        "size": size.as_str(),
        "instance": instance,
        "settings": settings,
        "refresh": spec.every.map(|every| json!({ "everySeconds": every })),
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
    };
    Ok((context, widget))
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
        let dir = self.config.state_dir.clone();
        inner.widgets.layout.get_or_insert_with(|| {
            dir.and_then(|dir| std::fs::read(dir.join(LAYOUT_FILE)).ok())
                .and_then(|raw| serde_json::from_slice::<Layout>(&raw).ok())
                .unwrap_or_default()
        })
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
                "title": entry.get("title").map_or_else(|| text(&package.manifest["name"]), text),
                "sizes": spec.sizes.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
                "defaultSize": spec.default_size.as_str(),
                "places": spec.places.iter().map(|p| p.as_str()).collect::<Vec<_>>(),
                "refresh": spec.every.map(|every| json!({ "everySeconds": every })),
            });
            if let Some(object) = row.as_object_mut() {
                if let Some(symbol) = entry.get("symbol").and_then(Value::as_str) {
                    object.insert("symbol".into(), Value::String(symbol.into()));
                }
                let description = entry
                    .get("description")
                    .map(text)
                    .unwrap_or_else(|| text(&package.manifest["description"]));
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
        let (result, revision) = {
            let mut inner = self.inner.lock().recover_poison();
            if let Some((_, value)) =
                inner.widgets.keys.iter().find(|(key, _)| *key == p.idempotency_key)
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
            apply(&mut next, place, p.edit, |app| specs.get(app).cloned())
                .map_err(|message| ApiError::new("apps.widgets.edit", message))?;
            // Under the supervisor lock: two pages' edits land one after the other.
            if let Some(dir) = &self.config.state_dir {
                write_durably(dir, LAYOUT_FILE, &next)
                    .map_err(|e| ApiError::new("operation.failed", e.to_string()))?;
            }
            let result = json!({ "layout": layout_json(&next, &shown, None) });
            *self.widget_layout_locked(&mut inner) = next.clone();
            if inner.widgets.keys.len() >= MAX_KEYS {
                inner.widgets.keys.pop_front();
            }
            inner.widgets.keys.push_back((p.idempotency_key, result.clone()));
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
            return Ok(json!({}));
        }
        mount.budget.settle(now, SETTLE);
        let missed = widget.every.is_some_and(|every| {
            now_ms.saturating_sub(widget.last_tick_ms) >= every.saturating_mul(1000)
        });
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
                    "batches": mount.budget.batches_in,
                    "sent": mount.budget.batches_out,
                    "held": mount.budget.held,
                    "step": mount.budget.step().as_str(),
                }))
            })
            .collect();
        meters.sort_by(|a, b| a["mount_id"].as_str().cmp(&b["mount_id"].as_str()));
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
        let delay = next_tick_delay(super::supervisor::now_ms(), every);
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
        self.send_tick_locked(&mut inner, key, super::supervisor::now_ms());
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
    std::fs::rename(&temp, dir.join(name))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(options: Value) -> Spec {
        Spec::from_entry(&json!({ "export": "r", "options": options }))
    }

    #[test]
    fn a_spec_defaults_to_one_small_size_in_both_places_with_no_tick() {
        let s = Spec::from_entry(&json!({ "export": "r" }));
        assert_eq!(s.sizes, vec![Size::Small]);
        assert_eq!(s.default_size, Size::Small);
        assert_eq!(s.places, vec![Place::Newtab, Place::Sidebar]);
        assert_eq!(s.every, None);
    }

    #[test]
    fn a_large_only_widget_never_goes_in_the_sidebar() {
        let s = spec(json!({ "sizes": ["large"] }));
        assert_eq!(s.places, vec![Place::Newtab]);
        let both = spec(json!({ "sizes": ["small", "large"], "defaultSize": "large" }));
        assert_eq!(both.default_in(Place::Sidebar), Some(Size::Small));
        assert_eq!(both.default_in(Place::Newtab), Some(Size::Large));
        assert_eq!(both.sizes_in(Place::Sidebar), vec![Size::Small]);
    }

    #[test]
    fn refresh_is_raised_to_the_floor_and_capped_at_a_day() {
        assert_eq!(spec(json!({ "refresh": { "everySeconds": 1 } })).every, Some(60));
        assert_eq!(spec(json!({ "refresh": { "everySeconds": 900 } })).every, Some(900));
        assert_eq!(spec(json!({ "refresh": { "everySeconds": 999_999 } })).every, Some(86_400));
    }

    #[test]
    fn ticks_fall_on_wall_clock_boundaries() {
        // A whole minute (and a whole quarter hour): 1_794_000_600_000 ms since the epoch.
        let base: u64 = 1_794_000_600_000;
        // 42.5 s past the minute: the next minute is 17.5 s away.
        assert_eq!(next_tick_delay(base + 42_500, 60), Duration::from_millis(17_500));
        assert_eq!(
            next_tick_delay(base, 60),
            Duration::from_secs(60),
            "on the boundary: a full minute"
        );
        assert_eq!(next_tick_delay(base + 1, 900), Duration::from_millis(899_999));
    }

    fn specs(app: &str) -> Option<Spec> {
        match app {
            "local/clock" => Some(spec(json!({ "sizes": ["small", "medium", "large"] }))),
            "local/todo" => {
                Some(spec(json!({ "sizes": ["medium", "large"], "places": ["newtab"] })))
            }
            _ => None,
        }
    }

    fn add(layout: &mut Layout, place: Place, app: &str, size: Option<&str>) -> Result<(), String> {
        apply(
            layout,
            place,
            Edit::Add { app: app.into(), size: size.map(str::to_string), before: None },
            specs,
        )
    }

    #[test]
    fn add_remove_resize_and_move_keep_one_ordered_layout_per_place() {
        let mut layout = Layout::default();
        add(&mut layout, Place::Newtab, "local/clock", None).unwrap();
        add(&mut layout, Place::Newtab, "local/todo", None).unwrap();
        add(&mut layout, Place::Sidebar, "local/clock", Some("medium")).unwrap();
        let ids = |l: &Layout, p: Place| {
            l.place(p).iter().map(|i| i.instance.clone()).collect::<Vec<_>>()
        };
        assert_eq!(ids(&layout, Place::Newtab), ["w1", "w2"]);
        assert_eq!(ids(&layout, Place::Sidebar), ["w3"]);
        assert_eq!(layout.newtab.get(1).map(|i| i.size), Some(Size::Medium), "todo's default");
        assert_eq!(layout.revision, 3);

        let edit = |l: &mut Layout, e: Edit| apply(l, Place::Newtab, e, specs);
        edit(&mut layout, Edit::Move { instance: "w2".into(), before: Some("w1".into()) }).unwrap();
        assert_eq!(ids(&layout, Place::Newtab), ["w2", "w1"]);
        edit(&mut layout, Edit::Move { instance: "w2".into(), before: None }).unwrap();
        assert_eq!(ids(&layout, Place::Newtab), ["w1", "w2"]);
        edit(&mut layout, Edit::Resize { instance: "w1".into(), size: "large".into() }).unwrap();
        assert_eq!(layout.newtab.first().map(|i| i.size), Some(Size::Large));
        edit(
            &mut layout,
            Edit::Configure { instance: "w1".into(), settings: json!({ "zone": "Asia/Tokyo" }) },
        )
        .unwrap();
        assert_eq!(
            layout.newtab.first().map(|i| i.settings.clone()),
            Some(json!({ "zone": "Asia/Tokyo" }).as_object().cloned().unwrap())
        );
        edit(&mut layout, Edit::Remove { instance: "w1".into() }).unwrap();
        assert_eq!(ids(&layout, Place::Newtab), ["w2"]);
        // Ids are never reused.
        add(&mut layout, Place::Newtab, "local/clock", None).unwrap();
        assert_eq!(ids(&layout, Place::Newtab), ["w2", "w4"]);
    }

    #[test]
    fn an_edit_the_widget_does_not_offer_is_refused_and_changes_nothing() {
        let mut layout = Layout::default();
        add(&mut layout, Place::Sidebar, "local/clock", None).unwrap();
        let before = layout.clone();
        assert!(
            add(&mut layout, Place::Sidebar, "local/clock", Some("large")).is_err(),
            "sidebar takes no large"
        );
        assert!(
            add(&mut layout, Place::Sidebar, "local/todo", None).is_err(),
            "todo is New Tab only"
        );
        assert!(
            add(&mut layout, Place::Newtab, "local/todo", Some("small")).is_err(),
            "todo draws no small"
        );
        assert!(
            add(&mut layout, Place::Newtab, "local/gone", None).is_err(),
            "not shown: not placed"
        );
        let side = |l: &mut Layout, e: Edit| apply(l, Place::Sidebar, e, specs);
        assert!(
            side(&mut layout, Edit::Resize { instance: "w1".into(), size: "large".into() })
                .is_err()
        );
        assert!(
            side(&mut layout, Edit::Move { instance: "w1".into(), before: Some("w9".into()) })
                .is_err()
        );
        assert!(
            side(&mut layout, Edit::Configure { instance: "w1".into(), settings: json!([1]) })
                .is_err()
        );
        let big = json!({ "x": "a".repeat(MAX_SETTINGS_BYTES) });
        assert!(
            side(&mut layout, Edit::Configure { instance: "w1".into(), settings: big }).is_err()
        );
        assert_eq!(layout, before);
    }

    #[test]
    fn a_place_holds_at_most_its_limit() {
        let mut layout = Layout::default();
        for _ in 0..MAX_PER_PLACE {
            add(&mut layout, Place::Newtab, "local/clock", None).unwrap();
        }
        assert!(add(&mut layout, Place::Newtab, "local/clock", None).is_err());
    }

    #[test]
    fn the_mount_context_is_built_here_and_refuses_what_the_widget_does_not_offer() {
        let s = spec(
            json!({ "sizes": ["small", "medium"], "refresh": { "everySeconds": 30 }, "places": ["sidebar"] }),
        );
        let mut layout = Layout::default();
        layout.sidebar.push(Item {
            instance: "w7".into(),
            app: "local/clock".into(),
            size: Size::Medium,
            settings: json!({ "zone": "UTC" }).as_object().cloned().unwrap(),
        });
        let (context, widget) =
            mount_context(&s, &json!({ "place": "sidebar", "size": "medium", "instance": "w7", "surface": "x", "settings": { "evil": 1 } }), &layout)
                .unwrap();
        assert_eq!(
            context,
            json!({ "surface": "widget", "place": "sidebar", "size": "medium", "instance": "w7",
                    "settings": { "zone": "UTC" }, "refresh": { "everySeconds": 60 } })
        );
        assert_eq!(widget.every, Some(60));
        assert!(widget.visible);
        for bad in [
            json!({ "place": "newtab", "size": "small", "instance": "w7" }),
            json!({ "place": "sidebar", "size": "large", "instance": "w7" }),
            json!({ "place": "sidebar", "size": "small" }),
            json!({ "place": "dock", "size": "small", "instance": "w7" }),
        ] {
            assert!(mount_context(&s, &bad, &layout).is_err(), "{bad}");
        }
    }
}
