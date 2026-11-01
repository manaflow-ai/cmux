//! Browser device emulation (`browser-devices-v1`, cx-ocbf3): the devices of
//! Chrome's device toolbar for every browser tab, CEF and WebKit alike.
//!
//! The daemon is the one owner. The built-in list is one data file compiled
//! in (`data/emulated-devices.json`): Chrome DevTools' own list, verbatim
//! (Chrome's JSONV1 keys, Chrome's order; `scripts/cmux-next/
//! import-chrome-devices.py` refreshes it), then newer devices Chrome does not
//! list yet (`"origin": "cmux"`, each with its `sources`). `chrome-annotations`
//! gives Chrome's rows the menu fields cmux rows carry themselves (`released`,
//! `brand`, `group`: phone, foldable, tablet, laptop, desktop, smart-display).
//! Custom devices
//! (`browser.devices.add_custom`) are rows of the home session's store, in
//! the same format. `browser.tab.emulate` keeps the chosen device and
//! orientation on the tab (`tab_state.emulation_json`), and every tab
//! snapshot shows the resolved values as `extra.emulation`: the numbers an
//! engine applies, and for Chromium the exact DevTools calls Chrome's device
//! mode sends. Frontends apply that record and decide nothing. A tab can
//! instead fit a desktop layout (`browser.tab.emulate {fit: "16:9"}`): the
//! record then names the aspect and the width bounds (`mode: "fit"`), and
//! the engine sizes the layout from its view (`resolve_fit`).

use std::sync::OnceLock;

use cmux_json::JsonSet as _;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Map, Value, json};

/// `browser.devices.*`, `browser.tab.emulate*` and `extra.emulation`.
pub const CAPABILITY: &str = "browser-devices-v1";
/// `fit` on `browser.tab.emulate` and the `mode: "fit"` record (cx-va1wd).
pub const FIT_CAPABILITY: &str = "browser-fit-v1";
/// A fixed layout width as `fit` ("1280") and `fit.value` (cx-2ftlq).
pub const FIT_WIDTH_CAPABILITY: &str = "browser-fit-width-v1";
/// The resource kind of the custom device list on `session.events`.
pub(crate) const RESOURCE: &str = "browser_device";
/// The id of the one custom device list.
pub(crate) const ID: &str = "custom";

const BUILT_IN: &str = include_str!("../../data/emulated-devices.json");
/// Most custom devices kept (Chrome has no limit; this bounds the row set).
pub(crate) const MAX_CUSTOM: usize = 200;
/// Largest stored device object.
const MAX_DEVICE_BYTES: usize = 16 * 1024;
const MAX_TITLE_CHARS: usize = 128;
const MAX_USER_AGENT_BYTES: usize = 1024;
/// Chrome's device editor limits (DeviceModeModel MinDeviceSize/MaxDeviceSize,
/// MaxDeviceScaleFactor).
const MIN_SIZE: i64 = 50;
const MAX_SIZE: i64 = 9999;
const MAX_SCALE: f64 = 10.0;

struct BuiltIn {
    chrome: Value,
    /// The Chromium milestone of the list ("154"): the version a device's
    /// "%s" becomes.
    chromium: String,
    devices: Vec<Value>,
}

fn built_in() -> &'static BuiltIn {
    static LIST: OnceLock<BuiltIn> = OnceLock::new();
    LIST.get_or_init(|| {
        let file: Value = serde_json::from_str(BUILT_IN).expect("emulated-devices.json parses");
        let chrome = file.get("chrome").cloned().unwrap_or(Value::Null);
        let chromium =
            chrome.get("chromium").and_then(Value::as_str).unwrap_or_default().to_string();
        let notes = file.get("chrome-annotations").and_then(Value::as_object);
        let devices = file
            .get("devices")
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter(|device| check(device).is_ok())
                    .map(|device| annotate(device, notes))
                    .collect()
            })
            .unwrap_or_default();
        BuiltIn { chrome, chromium, devices }
    })
}

pub(crate) fn create_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS browser_custom_devices (
           title TEXT PRIMARY KEY NOT NULL,
           device_json TEXT NOT NULL,
           position INTEGER NOT NULL
         );",
    )?;
    Ok(())
}

/// Additive: a `tab_state` table an older build created has no emulation
/// column. Older builds name their columns, so they keep using the table.
pub(crate) fn add_tab_emulation_column(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let has_column = transaction
        .prepare("PRAGMA table_info(tab_state)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .any(|column| column == "emulation_json");
    if !has_column {
        transaction.execute_batch("ALTER TABLE tab_state ADD COLUMN emulation_json TEXT;")?;
    }
    Ok(())
}

/// The custom devices, oldest first.
fn custom(connection: &Connection) -> anyhow::Result<Vec<Value>> {
    let mut statement = connection
        .prepare("SELECT device_json FROM browser_custom_devices ORDER BY position, title")?;
    let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
    let mut devices = Vec::new();
    for row in rows {
        // A row that no longer reads is left out alone (as Chrome does).
        if let Ok(device) = serde_json::from_str::<Value>(&row?) {
            devices.push(device);
        }
    }
    Ok(devices)
}

/// `browser.devices.list`: the custom devices, then the built-in ones, each
/// with Chrome's menu `category` and cmux's finer `group` and `brand`.
pub(crate) fn list(connection: &Connection) -> anyhow::Result<Value> {
    let list = built_in();
    let mut devices = custom(connection)?;
    devices.extend(list.devices.iter().cloned());
    for device in &mut devices {
        let (category, group, brand) = (category(device), group(device), brand(device));
        if let Some(object) = device.as_object_mut() {
            object.insert("category".into(), json!(category));
            object.insert("group".into(), json!(group));
            object.insert("brand".into(), json!(brand));
        }
    }
    Ok(json!({"chrome": list.chrome, "devices": devices}))
}

/// Chrome's device menu section of `device` (DeviceModeView's
/// `deviceCategory`): mobile, foldable, tablet-desktop or smart-display.
fn category(device: &Value) -> &'static str {
    let kind = device.get("type").and_then(Value::as_str).unwrap_or_default();
    if kind == "foldable" || spans(device) {
        "foldable"
    } else if kind == "smart-display" {
        "smart-display"
    } else if matches!(kind, "tablet" | "notebook" | "desktop") {
        "tablet-desktop"
    } else {
        "mobile"
    }
}

/// The groups of cmux's device menu, in menu order (finer than Chrome's
/// `category`: laptops and desktops apart from tablets).
pub(crate) const GROUPS: [&str; 6] =
    ["phone", "foldable", "tablet", "laptop", "desktop", "smart-display"];

/// A Chrome row with the fields the data file's `chrome-annotations` give it
/// by title (`released`, `brand`, `group`): Chrome's own rows stay verbatim
/// in `devices`, so `import-chrome-devices.py` can rewrite them.
fn annotate(device: &Value, notes: Option<&Map<String, Value>>) -> Value {
    let mut device = device.clone();
    let title = device["title"].as_str().unwrap_or_default().to_string();
    if let (Some(extra), Some(object)) = (
        notes.and_then(|notes| notes.get(&title)).and_then(Value::as_object),
        device.as_object_mut(),
    ) {
        for (key, value) in extra {
            object.entry(key.clone()).or_insert_with(|| value.clone());
        }
    }
    device
}

/// The menu group of `device`: its own `group` when it names one of
/// `GROUPS`, else from Chrome's `type` and its spanned screens.
fn group(device: &Value) -> &'static str {
    if let Some(named) = device.get("group").and_then(Value::as_str)
        && let Some(group) = GROUPS.iter().find(|group| **group == named)
    {
        return group;
    }
    match device.get("type").and_then(Value::as_str).unwrap_or_default() {
        _ if spans(device) => "foldable",
        "foldable" => "foldable",
        "smart-display" => "smart-display",
        "tablet" => "tablet",
        "notebook" => "laptop",
        "desktop" => "desktop",
        _ => "phone",
    }
}

/// The maker the menu files `device` under ("Other" when the row names none).
fn brand(device: &Value) -> String {
    match device.get("brand").and_then(Value::as_str).map(str::trim) {
        Some(brand) if !brand.is_empty() => brand.to_string(),
        _ => "Other".to_string(),
    }
}

/// `browser.devices.add_custom`: stores `device` (Chrome's JSONV1 format);
/// a custom device with the same title is replaced in place. Returns the
/// stored device (with `origin: "custom"`).
pub(crate) fn add_custom(transaction: &Transaction<'_>, device: &Value) -> anyhow::Result<Value> {
    let mut device = device.clone();
    check(&device).map_err(|reason| anyhow::anyhow!("bad request: {reason}"))?;
    if let Some(object) = device.as_object_mut() {
        object.insert("origin".into(), json!("custom"));
    }
    let text = serde_json::to_string(&device)?;
    anyhow::ensure!(
        text.len() <= MAX_DEVICE_BYTES,
        "bad request: a device is at most {MAX_DEVICE_BYTES} bytes of JSON"
    );
    let title = device["title"].as_str().unwrap_or_default().to_string();
    let exists = transaction
        .query_row("SELECT 1 FROM browser_custom_devices WHERE title = ?1", [&title], |_| Ok(()))
        .optional()?
        .is_some();
    if exists {
        transaction.execute(
            "UPDATE browser_custom_devices SET device_json = ?2 WHERE title = ?1",
            params![title, text],
        )?;
    } else {
        let count: i64 =
            transaction
                .query_row("SELECT COUNT(*) FROM browser_custom_devices", [], |row| row.get(0))?;
        anyhow::ensure!(
            (count as usize) < MAX_CUSTOM,
            "bad request: at most {MAX_CUSTOM} custom devices; remove one first"
        );
        transaction.execute(
            "INSERT INTO browser_custom_devices(title, device_json, position)
             VALUES(?1, ?2, COALESCE((SELECT MAX(position) + 1 FROM browser_custom_devices), 0))",
            params![title, text],
        )?;
    }
    Ok(device)
}

/// `browser.devices.remove_custom`: whether a device was removed. Tabs that
/// emulate it keep their own copy.
pub(crate) fn remove_custom(transaction: &Transaction<'_>, title: &str) -> anyhow::Result<bool> {
    let title = title.trim();
    Ok(transaction.execute("DELETE FROM browser_custom_devices WHERE title = ?1", [title])? > 0)
}

/// What `browser.tab.emulate` asks for.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum EmulationChange {
    /// A device by title (`device`), an inline device (`custom`), or neither
    /// (another orientation of the device the tab emulates).
    Set {
        device: Option<String>,
        custom: Option<Value>,
        orientation: Option<String>,
    },
    /// Fit a desktop layout into the tab's view (`fit`): of aspect `W:H`
    /// ("16:9") at the view's height, or of a fixed CSS width ("1280").
    Fit(String),
    Clear,
}

/// The stored emulation of a tab after `change`: `{device, orientation}`,
/// the device object copied in, so the tab keeps it when the list changes,
/// or `{fit: {aspect: [W, H]}}` for a fit.
/// `None` clears. Errors start with "bad request: ".
pub(crate) fn stored_emulation(
    transaction: &Transaction<'_>,
    tab_id: &str,
    change: &EmulationChange,
) -> anyhow::Result<Option<String>> {
    let (device, custom, orientation) = match change {
        EmulationChange::Clear => return Ok(None),
        EmulationChange::Fit(value) => {
            let stored = match parse_fit_width(value) {
                Some(width) => json!({"fit": {"width": width?}}),
                None => {
                    let (width, height) = parse_aspect(value)?;
                    json!({"fit": {"aspect": [width, height]}})
                }
            };
            return Ok(Some(serde_json::to_string(&stored)?));
        }
        EmulationChange::Set { device, custom, orientation } => (device, custom, orientation),
    };
    let device = match (device, custom) {
        (Some(_), Some(_)) => anyhow::bail!("bad request: give device or custom, not both"),
        (Some(name), None) => find(transaction, name)?,
        (None, Some(custom)) => {
            check(custom).map_err(|reason| anyhow::anyhow!("bad request: {reason}"))?;
            let mut custom = custom.clone();
            if let Some(object) = custom.as_object_mut() {
                object.insert("origin".into(), json!("custom"));
            }
            custom
        }
        (None, None) => {
            let current: Option<String> = transaction
                .query_row(
                    "SELECT emulation_json FROM tab_state WHERE tab_id = ?1",
                    [tab_id],
                    |row| row.get(0),
                )
                .optional()?
                .flatten();
            let current = current.and_then(|text| serde_json::from_str::<Value>(&text).ok());
            match current.and_then(|stored| stored.get("device").cloned()) {
                Some(device) => device,
                None => anyhow::bail!(
                    "bad request: the tab emulates no device; name one (browser.devices.list lists them)"
                ),
            }
        }
    };
    // A stored custom row is checked again: a newer limit may refuse it.
    check(&device).map_err(|reason| anyhow::anyhow!("bad request: {reason}"))?;
    let orientation = pick_orientation(&device, orientation.as_deref())?;
    let stored = serde_json::to_string(&json!({"device": device, "orientation": orientation}))?;
    anyhow::ensure!(
        stored.len() <= MAX_DEVICE_BYTES,
        "bad request: a device is at most {MAX_DEVICE_BYTES} bytes of JSON"
    );
    // Only what resolves is stored, so extra.emulation never goes missing silently.
    anyhow::ensure!(resolve(&stored).is_some(), "bad request: the device does not resolve");
    Ok(Some(stored))
}

/// The device titled `name`: an exact title first (custom devices win), then
/// a match that ignores case, spaces and punctuation.
fn find(connection: &Connection, name: &str) -> anyhow::Result<Value> {
    let name = name.trim();
    let mut all = custom(connection)?;
    all.extend(built_in().devices.iter().cloned());
    let title = |device: &Value| device["title"].as_str().unwrap_or_default().to_string();
    if let Some(device) = all.iter().find(|device| title(device) == name) {
        return Ok(device.clone());
    }
    let key = |text: &str| -> String {
        text.chars()
            .filter(|c| c.is_alphanumeric() || *c == '+')
            .flat_map(char::to_lowercase)
            .collect()
    };
    all.iter().find(|device| key(&title(device)) == key(name)).cloned().ok_or_else(|| {
        anyhow::anyhow!(
            "bad request: no device named {name:?}; browser.devices.list lists the devices"
        )
    })
}

/// Chrome's mode orientations, and the names a person types for them.
fn orientation_name(value: &str) -> Option<&'static str> {
    Some(match value.trim().to_ascii_lowercase().as_str() {
        "vertical" | "portrait" => "vertical",
        "horizontal" | "landscape" => "horizontal",
        "vertical-spanned" | "unfolded-portrait" => "vertical-spanned",
        "horizontal-spanned" | "unfolded-landscape" => "horizontal-spanned",
        _ => return None,
    })
}

/// The orientations `device` has, in Chrome's mode order; a device without
/// modes has vertical and horizontal (Chrome's default).
fn orientations(device: &Value) -> Vec<&'static str> {
    let named: Vec<String> = match device.get("modes").and_then(Value::as_array) {
        Some(modes) => modes
            .iter()
            .filter_map(|mode| mode.get("orientation").and_then(Value::as_str).map(str::to_string))
            .collect(),
        None => vec!["vertical".into(), "horizontal".into()],
    };
    let mut seen = Vec::new();
    for name in named {
        if let Some(name) = orientation_name(&name)
            && !seen.contains(&name)
            && (!name.ends_with("-spanned") || spans(device))
            && device["screen"].get(name).is_some_and(Value::is_object)
        {
            seen.push(name);
        }
    }
    seen
}

/// Chrome reads a spanned screen only for a dual-screen or foldable device.
fn spans(device: &Value) -> bool {
    ["dual-screen", "foldable-screen"].iter().any(|key| device.get(*key) == Some(&json!(true)))
}

/// A string without control characters (a user agent or title goes to the engine as is).
fn plain(text: &str) -> bool {
    !text.chars().any(char::is_control)
}

fn pick_orientation(device: &Value, asked: Option<&str>) -> anyhow::Result<&'static str> {
    let available = orientations(device);
    let title = device["title"].as_str().unwrap_or_default();
    let Some(asked) = asked else {
        return available
            .first()
            .copied()
            .ok_or_else(|| anyhow::anyhow!("bad request: {title:?} has no orientation"));
    };
    let name = orientation_name(asked).ok_or_else(|| {
        anyhow::anyhow!(
            "bad request: unknown orientation {asked:?}; use vertical, horizontal, vertical-spanned or horizontal-spanned"
        )
    })?;
    anyhow::ensure!(
        available.contains(&name),
        "bad request: {title:?} has no {name} orientation; it has {}",
        available.join(", ")
    );
    Ok(name)
}

/// Why `device` cannot be emulated, if it cannot: Chrome's editor limits.
fn check(device: &Value) -> Result<(), String> {
    let object = device.as_object().ok_or("a device is a JSON object")?;
    let title = object.get("title").and_then(Value::as_str).unwrap_or_default();
    if title.trim().is_empty()
        || title.trim() != title
        || title.chars().count() > MAX_TITLE_CHARS
        || !plain(title)
    {
        return Err(format!(
            "title must be 1 to {MAX_TITLE_CHARS} characters, without control characters or edge spaces"
        ));
    }
    let screen = object.get("screen").and_then(Value::as_object).ok_or("screen is missing")?;
    let ratio = screen.get("device-pixel-ratio").and_then(Value::as_f64).unwrap_or(0.0);
    if !(ratio > 0.0 && ratio <= MAX_SCALE) {
        return Err(format!("{title}: device-pixel-ratio must be above 0 and at most {MAX_SCALE}"));
    }
    for name in ["vertical", "horizontal", "vertical-spanned", "horizontal-spanned"] {
        let Some(size) = screen.get(name) else {
            if matches!(name, "vertical" | "horizontal") {
                return Err(format!("{title}: screen.{name} is missing"));
            }
            continue;
        };
        for side in ["width", "height"] {
            let value = size.get(side).and_then(Value::as_i64).unwrap_or(0);
            if !(MIN_SIZE..=MAX_SIZE).contains(&value) {
                return Err(format!(
                    "{title}: screen.{name}.{side} must be {MIN_SIZE} to {MAX_SIZE}"
                ));
            }
        }
        // A fold or gap (Chrome's parseHinge): whole CSS px of 0 or more
        // (Chrome's own Asus Zenbook Fold hinge is wider than its screen).
        if let Some(hinge) = size.get("hinge") {
            let number = |key: &str| hinge.get(key).and_then(Value::as_i64).filter(|v| *v >= 0);
            if ["x", "y", "width", "height"].iter().any(|key| number(key).is_none()) {
                return Err(format!(
                    "{title}: screen.{name}.hinge needs x, y, width and height of 0 or more"
                ));
            }
        }
    }
    if let Some(agent) = object.get("user-agent") {
        match agent.as_str() {
            Some(agent) if agent.len() <= MAX_USER_AGENT_BYTES && plain(agent) => {}
            _ => {
                return Err(format!(
                    "{title}: user-agent must be a string of at most {MAX_USER_AGENT_BYTES} bytes without control characters"
                ));
            }
        }
    }
    if let Some(capabilities) = object.get("capabilities")
        && !capabilities.as_array().is_some_and(|list| list.iter().all(Value::is_string))
    {
        return Err(format!("{title}: capabilities must be a list of strings"));
    }
    Ok(())
}

/// The narrowest and widest desktop layout width a fit uses, in CSS px:
/// 1024 is the usual desktop breakpoint, 1920 a 1080p desktop.
const FIT_MIN_WIDTH: i64 = 1024;
const FIT_MAX_WIDTH: i64 = 1920;
/// The largest side of a fit's aspect ratio ("16:9", "21:9", "4:3").
const FIT_MAX_ASPECT_SIDE: i64 = 64;

/// The narrowest and widest fixed layout width of a fit (`fit: "1280"`).
const FIT_FIXED_MIN: i64 = 640;
const FIT_FIXED_MAX: i64 = 3840;

/// A fixed-width fit ("1280"): `None` when `text` is not a bare number
/// (then it is an aspect ratio), an error when the number is out of range.
fn parse_fit_width(text: &str) -> Option<anyhow::Result<i64>> {
    let text = text.trim();
    if text.is_empty() || !text.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    Some(text.parse::<i64>().ok().filter(|v| (FIT_FIXED_MIN..=FIT_FIXED_MAX).contains(v)).ok_or_else(|| {
        anyhow::anyhow!(
            "bad request: a fixed fit width is {FIT_FIXED_MIN} to {FIT_FIXED_MAX} CSS px, such as 1280"
        )
    }))
}

/// "W:H" (or "WxH") as whole numbers of 1 to 64 whose ratio is 1:4 to 4:1.
fn parse_aspect(text: &str) -> anyhow::Result<(i64, i64)> {
    let bad = || {
        anyhow::anyhow!(
            "bad request: fit takes an aspect ratio W:H such as 16:9 (whole numbers of 1 to {FIT_MAX_ASPECT_SIDE}, at most 4:1 either way) or a layout width of {FIT_FIXED_MIN} to {FIT_FIXED_MAX} CSS px such as 1280"
        )
    };
    let (width, height) = text.trim().split_once([':', 'x', 'X']).ok_or_else(bad)?;
    let side = |value: &str| {
        value.trim().parse::<i64>().ok().filter(|v| (1..=FIT_MAX_ASPECT_SIDE).contains(v))
    };
    let (width, height) = (side(width).ok_or_else(bad)?, side(height).ok_or_else(bad)?);
    if width > height * 4 || height > width * 4 {
        return Err(bad());
    }
    Ok((width, height))
}

/// `extra.emulation` of a stored fit `{"fit": {"aspect": [W, H]}}` (or
/// `{"fit": {"width": N}}`: min_width = max_width = N, so the layout is N CSS
/// px wide whatever the view's height; `fit.value` names which): a desktop
/// layout as wide as the view would be at aspect W:H at its height (between
/// `min_width` and `max_width` CSS px), scaled down to the view's width; the
/// layout's height is the view's height over that scale, so the page fills
/// the whole view. A view at least that wide shows the page as is. The
/// engine computes the numbers from its view size; the calls carry zeros
/// for width, height and scale.
fn resolve_fit(fit: &Value) -> Option<Value> {
    let (value, text, width, height, min_width, max_width) = match fit.get("width") {
        Some(fixed) => {
            let fixed = fixed.as_i64().filter(|v| (FIT_FIXED_MIN..=FIT_FIXED_MAX).contains(v))?;
            (fixed.to_string(), "16:9".to_string(), 16, 9, fixed, fixed)
        }
        None => {
            let aspect = fit.get("aspect")?.as_array()?;
            let [width, height] = aspect.as_slice() else { return None };
            let text = format!("{}:{}", width.as_i64()?, height.as_i64()?);
            let (width, height) = parse_aspect(&text).ok()?;
            (text.clone(), text, width, height, FIT_MIN_WIDTH, FIT_MAX_WIDTH)
        }
    };
    let metrics = json!({
        "width": 0,
        "height": 0,
        "deviceScaleFactor": 0,
        "mobile": false,
        "scale": 1,
        "dontSetVisibleSize": true,
    });
    Some(json!({
        "mode": "fit",
        "fit": {
            "value": value,
            "aspect": text,
            "aspect_width": width,
            "aspect_height": height,
            "min_width": min_width,
            "max_width": max_width,
        },
        "device_scale_factor": 0,
        "mobile": false,
        "touch": false,
        "user_agent": "",
        "chromium_calls": [
            {"method": "Emulation.setDeviceMetricsOverride", "params": metrics},
            {"method": "Emulation.setUserAgentOverride", "params": {"userAgent": ""}},
            {"method": "Emulation.setTouchEmulationEnabled", "params": {"enabled": false}},
            {"method": "Emulation.setEmitTouchEventsForMouse", "params": {"enabled": false}},
        ],
    }))
}

/// The user agent with Chrome's version in place of "%s", as DevTools
/// patches it (`patchUserAgentWithChromeVersion`): the first "%s" is the
/// reduced version "<major>.0.0.0", the second "<major>.0.100.0".
fn patch_user_agent(agent: &str, major: &str) -> String {
    if major.is_empty() {
        return agent.to_string();
    }
    let mut result = agent.to_string();
    for value in [format!("{major}.0.0.0"), format!("{major}.0.100.0")] {
        match result.find("%s") {
            Some(index) => result.replace_range(index..index + 2, &value),
            None => break,
        }
    }
    result
}

/// Every string in `value` with "%s" patched as in the user agent.
fn patch_metadata(value: &Value, major: &str) -> Value {
    match value {
        Value::String(text) => Value::String(patch_user_agent(text, major)),
        Value::Array(items) => {
            Value::Array(items.iter().map(|v| patch_metadata(v, major)).collect())
        }
        Value::Object(map) => {
            Value::Object(map.iter().map(|(k, v)| (k.clone(), patch_metadata(v, major))).collect())
        }
        other => other.clone(),
    }
}

/// `extra.emulation` of a tab: the resolved values of the stored
/// `{device, orientation}`, or `None` when it does not resolve.
pub(crate) fn resolve(stored: &str) -> Option<Value> {
    let stored: Value = serde_json::from_str(stored).ok()?;
    if let Some(fit) = stored.get("fit") {
        return resolve_fit(fit);
    }
    let device = stored.get("device")?;
    check(device).ok()?;
    let orientation = pick_orientation(device, stored.get("orientation")?.as_str()).ok()?;
    let screen = &device["screen"];
    let size = &screen[orientation];
    let (width, height) = (size["width"].as_i64()?, size["height"].as_i64()?);
    let ratio = screen["device-pixel-ratio"].as_f64()?;
    let capabilities: Vec<&str> = device
        .get("capabilities")
        .and_then(Value::as_array)
        .map(|list| list.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let mobile = capabilities.contains(&"mobile");
    let touch = capabilities.contains(&"touch");
    let major = built_in().chromium.clone();
    let user_agent = patch_user_agent(device["user-agent"].as_str().unwrap_or_default(), &major);
    let portrait = matches!(orientation, "vertical" | "vertical-spanned");
    let screen_orientation = json!({
        "type": if portrait { "portraitPrimary" } else { "landscapePrimary" },
        "angle": if portrait { 0 } else { 90 },
    });
    // A spanned (open) foldable with a hinge: the fold as a display feature.
    let display_feature = orientation
        .ends_with("-spanned")
        .then(|| size.get("hinge"))
        .flatten()
        .filter(|hinge| hinge.is_object())
        .map(|hinge| {
            let vertical = orientation == "vertical-spanned";
            json!({
                "orientation": if vertical { "vertical" } else { "horizontal" },
                "offset": if vertical { &hinge["x"] } else { &hinge["y"] },
                "maskLength": if vertical { &hinge["width"] } else { &hinge["height"] },
            })
        });
    let posture = if display_feature.is_some() { "folded" } else { "continuous" };
    // Client hints go with a user agent only (DevTools sends them together),
    // as the device gives them, "%s" patched as in the user agent
    // (patchUserAgentMetadataWithChromeVersion). Without brands the engine
    // keeps its own brand list, as in Chrome.
    let metadata = device
        .get("user-agent-metadata")
        .filter(|meta| meta.is_object() && !user_agent.is_empty())
        .map(|meta| patch_metadata(meta, &major));
    // The selected mode's safe-area insets (Chrome sends them only behind
    // its devToolsMobileSafeAreaEmulation flag, so no call carries them).
    let safe_area = device
        .get("modes")
        .and_then(Value::as_array)
        .and_then(|modes| {
            modes.iter().find(|mode| {
                mode.get("orientation").and_then(Value::as_str).and_then(orientation_name)
                    == Some(orientation)
            })
        })
        .and_then(|mode| mode.get("safe-area-insets"))
        .cloned();
    let mut metrics = Map::new();
    for (key, value) in [
        ("width", json!(width)),
        ("height", json!(height)),
        ("deviceScaleFactor", json!(ratio)),
        ("mobile", json!(mobile)),
        ("scale", json!(1)),
        ("screenWidth", json!(width)),
        ("screenHeight", json!(height)),
        ("positionX", json!(0)),
        ("positionY", json!(0)),
        // The view keeps the pane's size (DevTools sends it too).
        ("dontSetVisibleSize", json!(true)),
        ("screenOrientation", screen_orientation.clone()),
        ("devicePosture", json!({"type": posture})),
    ] {
        metrics.insert(key.into(), value);
    }
    if let Some(feature) = &display_feature {
        metrics.insert("displayFeature".into(), feature.clone());
    }
    let mut agent = json!({"userAgent": user_agent});
    if let Some(metadata) = &metadata {
        agent.set("userAgentMetadata", metadata.clone());
    }
    let touch_call = if touch {
        json!({"enabled": true, "maxTouchPoints": 1})
    } else {
        json!({"enabled": false})
    };
    let chromium_calls = json!([
        {"method": "Emulation.setDeviceMetricsOverride", "params": metrics},
        {"method": "Emulation.setUserAgentOverride", "params": agent},
        {"method": "Emulation.setTouchEmulationEnabled", "params": touch_call},
        {"method": "Emulation.setEmitTouchEventsForMouse",
         "params": {"enabled": touch, "configuration": if mobile { "mobile" } else { "desktop" }}},
    ]);
    Some(json!({
        "device": device["title"],
        "origin": device.get("origin").cloned().unwrap_or(json!("custom")),
        "orientation": orientation,
        "orientations": orientations(device),
        "width": width,
        "height": height,
        "device_scale_factor": ratio,
        "mobile": mobile,
        "touch": touch,
        "user_agent": user_agent,
        "user_agent_metadata": metadata,
        "screen_orientation": screen_orientation,
        "display_feature": display_feature,
        "device_posture": posture,
        "safe_area_insets": safe_area,
        "chromium_calls": chromium_calls,
    }))
}
