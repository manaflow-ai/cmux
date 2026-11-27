//! The settings whose parse is more than a plain bool or choice: Swift `AgentMouseSetting`,
//! `BrowserPasswordsSetting`, `BrowserVerificationAutofillSetting`, `ClosedHistoryRetentionSetting`,
//! `ChromePlacementSetting`, `ChromeStyleSetting`, `FontSmoothingSetting`, `HomeServerSetting`,
//! `DeviceHubSettings`, `HoverCardSettings`, `InterfaceScaleSetting`, `MenuLookSetting`,
//! `MotionCategoriesSetting`, `NewTabTemplate`, `NowPlayingSettings`, `PaletteRankingSetting`,
//! `PaletteScopePrefixes`, `QuitBehaviorSetting`, `ReducedBackgroundsSetting`, `RemoteLocalhostSetting`,
//! `ScreenshotsSettings`, `SessionSettings`, `SurfaceBackgroundSetting`, `TrustSettings`,
//! `UpdatesSettings`, the window titlebar settings, `WorkspaceHibernationSettings`,
//! `WorkspaceListSettings`, `AppearanceTuningSetting`, `AutoArchiveSettings`, `FeatureTipBudget`,
//! `RecentFonts`.
//!
//! - `custom.read` `{name, root, home?}` answers `{values, diagnostics}`: `values` is the typed
//!   setting under the Swift field names (an absent or refused key holds its schema default, so
//!   the app never repeats a default), `diagnostics` the refusals as `{kind, path, message}` in the
//!   wording Swift gave them. `name` is one of [`NAMES`]. The defaults, choices and ranges are the
//!   embedded schema's rows, the one source the generated Swift constants also come from.
//! - `recent_fonts.recorded` `{family, list}` answers `{list}`; `feature_tips.is_open`
//!   `{lastShownAt?, at}` (seconds) answers `{open}`.

use serde_json::{Map, Value, json};

use super::{OpError, string};
use crate::domains::Domains;
use crate::keypath::key_path;
use crate::migrations::renamed;
use crate::schema::{self, Kind, NumberRange, Row, Schema};
use crate::value::value_at;

/// The settings `custom.read` answers.
pub const NAMES: [&str; 34] = [
    "agent_mouse",
    "browser_passwords",
    "verification_autofill",
    "closed_history",
    "chrome_placement",
    "chrome_style",
    "font_smoothing",
    "home_server",
    "device_hub",
    "hover_cards",
    "interface_scale",
    "menu_look",
    "motion_categories",
    "new_tab_template",
    "now_playing",
    "palette_ranking",
    "palette_scope_prefixes",
    "quit_behavior",
    "reduced_backgrounds",
    "remote_localhost",
    "screenshots",
    "sessions",
    "surface_backgrounds",
    "trust",
    "updates",
    "window_titlebar",
    "titlebar_buttons",
    "plus_button",
    "workspace_hibernation",
    "workspace_list",
    "appearance_tuning",
    "auto_archive",
    "chat_diagnostics",
    "reduced_backgrounds_notes",
];

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "custom.read" => read(request),
        "recent_fonts.recorded" => recent_fonts_recorded(request),
        "feature_tips.is_open" => feature_tips_is_open(request),
        _ => return None,
    })
}

fn read(request: &Value) -> Result<Value, OpError> {
    let name = string(request, "name")?;
    let root = request.get("root").ok_or_else(|| OpError::Invalid("expected `root`".to_owned()))?;
    let home = request.get("home").and_then(Value::as_str).unwrap_or_default();
    let mut reader = Read::new(root);
    match name {
        "agent_mouse" => agent_mouse(&mut reader),
        "browser_passwords" => descriptors(
            &mut reader,
            &[
                ("offerToSave", "browser.passwords.offerToSave"),
                ("generate", "browser.passwords.generate"),
                ("allowExport", "browser.passwords.allowExport"),
            ],
        ),
        "verification_autofill" => verification_autofill(&mut reader),
        "closed_history" => closed_history(&mut reader),
        "chrome_placement" => chrome_placement(&mut reader),
        "chrome_style" => reader.choice("chromeStyle", "appearance.chromeStyle"),
        "font_smoothing" => font_smoothing(&mut reader),
        "home_server" => home_server(&mut reader),
        "device_hub" => device_hub(&mut reader),
        "hover_cards" => hover_cards(&mut reader),
        "interface_scale" => interface_scale(&mut reader),
        "menu_look" => menu_look(&mut reader),
        "motion_categories" => motion_categories(&mut reader),
        "new_tab_template" => new_tab_template(&mut reader),
        "now_playing" => now_playing(&mut reader),
        "palette_ranking" => palette_ranking(&mut reader),
        "palette_scope_prefixes" => palette_scope_prefixes(&mut reader),
        "quit_behavior" => quit_behavior(&mut reader),
        "reduced_backgrounds" => reader.flag("enabled", "ui.reducedBackgrounds"),
        "remote_localhost" => remote_localhost(&mut reader),
        "screenshots" => screenshots(&mut reader, home),
        "sessions" => sessions(&mut reader),
        "surface_backgrounds" => surface_backgrounds(&mut reader),
        "trust" => trust(&mut reader),
        "updates" => updates(&mut reader),
        "window_titlebar" => reader.choice("style", "window.titlebar"),
        "titlebar_buttons" => reader.choice("mode", "window.titlebarButtons"),
        "plus_button" => reader.choice("mode", "tabs.plusButton"),
        "workspace_hibernation" => workspace_hibernation(&mut reader),
        "workspace_list" => workspace_list(&mut reader),
        "appearance_tuning" => appearance_tuning(&mut reader),
        "auto_archive" => auto_archive(&mut reader),
        "chat_diagnostics" => chat_diagnostics(&mut reader),
        "reduced_backgrounds_notes" => reduced_backgrounds_notes(request, &mut reader),
        other => return Err(OpError::Invalid(format!("no setting `{other}`"))),
    }
    Ok(reader.finish())
}

/// One read of a settings root: the values it answers and the refusals it noted.
struct Read<'a> {
    root: &'a Value,
    schema: &'static Schema,
    values: Map<String, Value>,
    diagnostics: Vec<Value>,
    /// Keys this module asked for that the schema lacks (a typo): one diagnostic each.
    missing: std::cell::RefCell<Vec<String>>,
}

/// Swift's `Double` description: `60.0`, `0.35`.
fn double(number: f64) -> String {
    if number.fract() == 0.0 && number.abs() < 1e16 {
        format!("{number:.1}")
    } else {
        format!("{number}")
    }
}

/// A whole number as text (Swift `Int(x)`).
fn whole(number: f64) -> String {
    format!("{}", number as i64)
}

fn quoted(choices: impl IntoIterator<Item = impl AsRef<str>>) -> String {
    choices.into_iter().map(|c| format!("\"{}\"", c.as_ref())).collect::<Vec<_>>().join(", ")
}

fn number_json(number: f64) -> Value {
    json!(number)
}

impl<'a> Read<'a> {
    fn new(root: &'a Value) -> Self {
        Self {
            root,
            schema: Schema::embedded(),
            values: Map::new(),
            diagnostics: Vec::new(),
            missing: Default::default(),
        }
    }

    fn finish(mut self) -> Value {
        let mut missing = self.missing.take();
        missing.dedup();
        for key in missing {
            self.diagnostics.push(
                json!({"kind": "unknownRow", "path": key, "message": "the schema has no such row"}),
            );
        }
        json!({"values": self.values, "diagnostics": self.diagnostics})
    }

    /// The schema row; none only for a key typo, which this module's tests catch.
    fn row(&self, key: &str) -> Option<&'static Row> {
        let row = self.schema.row(key);
        if row.is_none() {
            self.missing.borrow_mut().push(key.to_owned());
        }
        row
    }

    fn at(&self, key: &str) -> Option<&'a Value> {
        value_at(self.root, &key_path(key))
    }

    fn refuse(&mut self, path: &str, message: &str) {
        self.diagnostics.push(json!({"kind": "invalidValue", "path": path, "message": message}));
    }

    /// The row's default, or null.
    fn default_of(&self, key: &str) -> Value {
        self.row(key).and_then(|row| row.default.clone()).unwrap_or(Value::Null)
    }

    fn set(&mut self, field: &str, value: Value) {
        self.values.insert(field.to_owned(), value);
    }

    fn number_range(&self, key: &str) -> NumberRange {
        match self.row(key).map(|row| &row.kind) {
            Some(Kind::Number(range) | Kind::ChoiceOrNumber(_, range)) => range.clone(),
            // Only a key typo: no bound, so nothing is refused for it.
            _ => NumberRange {
                min: f64::NEG_INFINITY,
                max: f64::INFINITY,
                step: 0.0,
                unit: String::new(),
                placeholder: 0.0,
            },
        }
    }

    fn choices_of(&self, key: &str) -> Vec<String> {
        match self.row(key).map(|row| &row.kind) {
            Some(Kind::Choice(choices)) => choices.iter().map(|c| c.value.clone()).collect(),
            _ => Vec::new(),
        }
    }

    /// `members` of the object at `parent` (Swift `ConfigFieldReader`): none when absent,
    /// one diagnostic "expected an object" when it is something else.
    fn object(&mut self, parent: &str) -> Option<&'a Map<String, Value>> {
        let value = self.at(parent)?;
        match value.as_object() {
            Some(members) => Some(members),
            None => {
                self.refuse(parent, "expected an object");
                None
            }
        }
    }

    // MARK: single keys

    /// A toggle at `key`: absent or refused is the default ("expected true or false").
    fn flag(&mut self, field: &str, key: &str) {
        let raw = self.at(key);
        self.flag_of(raw, field, key);
    }

    fn flag_of(&mut self, raw: Option<&Value>, field: &str, key: &str) {
        let mut value = self.default_of(key);
        match raw {
            Some(Value::Bool(flag)) => value = json!(flag),
            Some(_) => self.refuse(key, "expected true or false"),
            None => {}
        }
        self.set(field, value);
    }

    /// A choice at `key` (`expected one of "a", "b"`).
    fn choice(&mut self, field: &str, key: &str) {
        let raw = self.at(key);
        self.choice_of(raw, field, key);
    }

    fn choice_of(&mut self, raw: Option<&Value>, field: &str, key: &str) {
        let choices = self.choices_of(key);
        let mut value = self.default_of(key);
        if let Some(raw) = raw {
            match raw.as_str() {
                Some(text) if choices.iter().any(|c| c == text) => value = json!(text),
                _ => self.refuse(key, &format!("expected one of {}", quoted(&choices))),
            }
        }
        self.set(field, value);
    }

    /// A number a reader clamps (Swift `ConfigFieldReader.number`): a non-number is refused with
    /// "expected a number", one past the range is clamped and says so.
    fn clamped_of(&mut self, raw: Option<&Value>, field: &str, key: &str) {
        let range = self.number_range(key);
        let mut value = self.default_of(key);
        if let Some(raw) = raw {
            match raw.as_f64().filter(|x| x.is_finite()) {
                None => self.refuse(key, "expected a number"),
                Some(number) => {
                    if !(range.min..=range.max).contains(&number) {
                        let message =
                            format!("clamped to {}...{}", double(range.min), double(range.max));
                        self.refuse(key, &message);
                    }
                    value = number_json(number.clamp(range.min, range.max));
                }
            }
        }
        self.set(field, value);
    }

    /// A number the app refuses outside its range (`expected a number from 60 to 1000`).
    fn strict_of(&mut self, raw: Option<&Value>, field: &str, key: &str, message: Option<String>) {
        let range = self.number_range(key);
        let mut value = self.default_of(key);
        if let Some(raw) = raw {
            match raw.as_f64().filter(|x| range.min <= *x && *x <= range.max) {
                Some(number) => value = number_json(number),
                None => {
                    let message = message.unwrap_or_else(|| {
                        format!(
                            "expected a number from {} to {}",
                            whole(range.min),
                            whole(range.max)
                        )
                    });
                    self.refuse(key, &message);
                }
            }
        }
        self.set(field, value);
    }
}

// MARK: single-type settings

fn agent_mouse(read: &mut Read) {
    let motion = "browser.agentMouse.motion";
    let choices = read.choices_of(motion);
    let mut value = read.default_of(motion);
    if let Some(raw) = read.at(motion) {
        match raw.as_str() {
            Some(text) if choices.iter().any(|c| c == text) => value = json!(text),
            _ => read.refuse(motion, "expected \"human\" or \"instant\""),
        }
    }
    read.set("motion", value);
    let raw = read.at("browser.agentMouse.maxMoveMs");
    read.strict_of(raw, "maxMoveMs", "browser.agentMouse.maxMoveMs", None);
}

/// `(field, key)` descriptors that accept their row's value: a refusal is the schema's
/// expectation text ([`expectation`]), the value the default.
fn descriptors(read: &mut Read, fields: &[(&str, &str)]) {
    for (field, key) in fields {
        descriptor(read, field, key);
    }
}

fn descriptor(read: &mut Read, field: &str, key: &str) -> Option<Value> {
    let row = read.row(key)?;
    let mut value = read.default_of(key);
    let mut accepted = None;
    if let Some(raw) = read.at(key) {
        if schema::accepts(row, raw, &Domains::default()).is_ok() {
            value = raw.clone();
            accepted = Some(raw.clone());
        } else {
            let message = expectation(row);
            read.refuse(key, &message);
        }
    }
    read.set(field, value);
    accepted
}

/// Swift `OmnibarSettingsSchema.expectation`: the diagnostic text for a refused value.
pub(crate) fn expectation(row: &Row) -> String {
    match &row.kind {
        Kind::Toggle => "expected true or false".to_owned(),
        Kind::Choice(choices) => {
            format!("expected one of {}", quoted(choices.iter().map(|c| &c.value)))
        }
        Kind::Number(range) => {
            format!("expected a number from {} to {}", whole(range.min), whole(range.max))
        }
        Kind::Url
            if row.key == "browser.customSearchEngine.search"
                || row.key == "browser.customSearchEngine.suggest" =>
        {
            "expected a web address with %s or {searchTerms} where the typed text goes, or \"\""
                .to_owned()
        }
        Kind::Url => "expected a web address or \"\"".to_owned(),
        Kind::ChoiceOrNumber(choices, range) => format!(
            "expected one of {} or a number from {} to {}",
            quoted(choices.iter().map(|c| &c.value)),
            whole(range.min),
            whole(range.max)
        ),
        Kind::ChoiceOrUrl(choices, url_key) => format!(
            "expected one of {} or {{\"{url_key}\": \"http(s)://host[:port]\"}}",
            quoted(choices.iter().map(|c| &c.value))
        ),
        _ => "invalid value".to_owned(),
    }
}

fn verification_autofill(read: &mut Read) {
    descriptor(read, "enabled", "browser.verificationAutofill.enabled");
    let accepted = descriptor(read, "accounts", "browser.verificationAutofill.accounts");
    if let Some(Value::Array(items)) = accepted {
        let mut addresses: Vec<String> = Vec::new();
        for item in items.iter().filter_map(Value::as_str) {
            let address = item.trim().to_lowercase();
            if address.contains('@') && !addresses.contains(&address) {
                addresses.push(address);
            }
        }
        read.set("accounts", json!(addresses));
    }
}

fn closed_history(read: &mut Read) {
    for (field, key, expected) in [
        (
            "maxGroups",
            "history.closed.maxGroups",
            "expected a whole number of groups from 0 to 10000, such as 200",
        ),
        (
            "maxAgeDays",
            "history.closed.maxAgeDays",
            "expected a whole number of days from 0 to 3650, such as 30",
        ),
    ] {
        let range = read.number_range(key);
        let mut value = read.default_of(key);
        if let Some(raw) = read.at(key) {
            // Swift `intValue`: a whole number below 1e15.
            let whole_number = raw.as_f64().filter(|x| {
                x.fract() == 0.0 && x.abs() < 1e15 && (range.min..=range.max).contains(x)
            });
            match whole_number {
                Some(number) => value = json!(number as i64),
                None => read.refuse(key, expected),
            }
        }
        read.set(field, value);
    }
}

fn chrome_placement(read: &mut Read) {
    for (field, key) in [
        ("sidebarSide", "sidebar.side"),
        ("spacesPosition", "sidebar.spacesPosition"),
        ("spacesVisibility", "sidebar.spacesVisibility"),
        ("tabBarPosition", "tabs.barPosition"),
        ("tabBarOrder", "tabs.barOrder"),
        ("browserToolbarPosition", "browser.toolbarPosition"),
    ] {
        read.choice(field, key);
    }
}

fn font_smoothing(read: &mut Read) {
    let key = "appearance.fontSmoothing";
    // The first release's name for auto.
    if read.at(key).and_then(Value::as_str) == Some("system") {
        read.set("mode", json!("auto"));
    } else {
        read.choice("mode", key);
    }
}

fn quit_behavior(read: &mut Read) {
    let key = "app.quitBehavior";
    // "end" was the first release's end-keep-layout; "ask" (the removed alert) reads as the default.
    match read.at(key).and_then(Value::as_str) {
        Some("end") => read.set("behavior", json!("end-keep-layout")),
        Some("ask") => read.set("behavior", json!("keep")),
        _ => read.choice("behavior", key),
    }
}

fn home_server(read: &mut Read) {
    let key = "home.server";
    let message =
        "expected \"hosted\" or {\"selfHosted\": \"http://<name>.<tailnet>.ts.net:7320\"}";
    let mut value = json!({"mode": "hosted"});
    if let Some(raw) = read.at(key) {
        let choices = match read.row(key).map(|row| &row.kind) {
            Some(Kind::ChoiceOrUrl(choices, _)) => {
                choices.iter().map(|c| c.value.clone()).collect::<Vec<_>>()
            }
            _ => Vec::new(),
        };
        let parsed = match raw {
            Value::String(text) if choices.contains(text) => Some(json!({"mode": "hosted"})),
            Value::Object(members) if members.len() == 1 => members
                .get("selfHosted")
                .and_then(Value::as_str)
                .filter(|text| schema::is_http_origin(text))
                .map(|text| {
                    let origin = text.to_ascii_lowercase();
                    json!({"mode": "selfHosted", "url": origin.trim_end_matches('/')})
                }),
            _ => None,
        };
        match parsed {
            Some(parsed) => value = parsed,
            None => read.refuse(key, message),
        }
    }
    read.set("server", value);
}

fn device_hub(read: &mut Read) {
    let mut url = read.default_of("deviceHub.url");
    if let Some(members) = read.object("deviceHub")
        && let Some(raw) = members.get("url")
    {
        match raw.as_str() {
            Some(text) => url = json!(text),
            None => read.refuse("deviceHub.url", "expected a string"),
        }
    }
    read.set("url", url);
}

fn hover_cards(read: &mut Read) {
    let members = read.object("sidebar.hoverCards");
    let top = "sidebar.hoverCards";
    let field = |m: Option<&Map<String, Value>>, key: &str| m.and_then(|m| m.get(key)).cloned();
    read.flag_of(field(members, "enabled").as_ref(), "enabled", &format!("{top}.enabled"));
    read.clamped_of(field(members, "delay").as_ref(), "delayMilliseconds", &format!("{top}.delay"));
    read.choice_of(field(members, "layout").as_ref(), "layout", &format!("{top}.layout"));
    read.clamped_of(field(members, "maxRows").as_ref(), "maxRows", &format!("{top}.maxRows"));
    rounded(read, "maxRows");
    let sections = read.object("sidebar.hoverCards.sections");
    for (field_name, key) in [
        ("showsTimings", "timings"),
        ("showsPrompts", "prompts"),
        ("showsWaiting", "waiting"),
        ("showsGit", "git"),
        ("showsPorts", "ports"),
    ] {
        let raw = field(sections, key);
        read.flag_of(raw.as_ref(), field_name, &format!("{top}.sections.{key}"));
    }
    let groups = read.object("sidebar.hoverCards.groups");
    for (field_name, key) in
        [("groupsWorkspaceGroups", "workspaceGroups"), ("groupsTabGroups", "tabGroups")]
    {
        let raw = field(groups, key);
        read.flag_of(raw.as_ref(), field_name, &format!("{top}.groups.{key}"));
    }
    read.clamped_of(
        field(groups, "delay").as_ref(),
        "groupsDelayMilliseconds",
        &format!("{top}.groups.delay"),
    );
    read.choice_of(field(groups, "order").as_ref(), "groupsOrder", &format!("{top}.groups.order"));
    read.clamped_of(
        field(groups, "maxMembers").as_ref(),
        "groupsMaxMembers",
        &format!("{top}.groups.maxMembers"),
    );
    rounded(read, "groupsMaxMembers");
    let group_sections = read.object("sidebar.hoverCards.groups.sections");
    for (field_name, key) in [
        ("groupsShowsStatus", "status"),
        ("groupsShowsMembers", "members"),
        ("groupsShowsActivity", "activity"),
        ("groupsShowsGit", "git"),
        ("groupsShowsPorts", "ports"),
    ] {
        let raw = field(group_sections, key);
        read.flag_of(raw.as_ref(), field_name, &format!("{top}.groups.sections.{key}"));
    }
}

/// Swift `value.rounded()` on a field already read (half away from zero).
fn rounded(read: &mut Read, field: &str) {
    if let Some(number) = read.values.get(field).and_then(Value::as_f64) {
        read.set(field, number_json(number.round()));
    }
}

fn interface_scale(read: &mut Read) {
    let key = "appearance.interfaceScale";
    let range = read.number_range(key);
    let mut value = number_json(range.placeholder);
    if let Some(raw) = read.at(key) {
        match raw.as_f64().filter(|x| x.is_finite()) {
            None => read.refuse(key, "expected a scale from 0.9 to 1.25"),
            Some(number) => {
                if !(range.min..=range.max).contains(&number) {
                    read.refuse(key, "expected a scale from 0.9 to 1.25; clamped");
                }
                value = number_json(number.clamp(range.min, range.max));
            }
        }
    }
    read.set("scale", value);
}

fn menu_look(read: &mut Read) {
    for (field, key) in [
        ("cornerRadius", "appearance.menu.cornerRadius"),
        ("borderOpacity", "appearance.menu.borderOpacity"),
        ("padding", "appearance.menu.padding"),
        ("highlightRadius", "appearance.menu.highlightRadius"),
        ("rowHeight", "appearance.menu.rowHeight"),
        ("popoverPadding", "appearance.popover.padding"),
        ("progressHeight", "appearance.popover.progressHeight"),
    ] {
        let range = read.number_range(key);
        let mut value = Value::Null;
        if let Some(raw) = read.at(key) {
            match raw.as_f64().filter(|x| x.is_finite()) {
                None => {
                    let message = format!(
                        "expected a number from {} to {}",
                        double(range.min),
                        double(range.max)
                    );
                    read.refuse(key, &message);
                }
                Some(number) => {
                    if !(range.min..=range.max).contains(&number) {
                        let message =
                            format!("clamped to {}...{}", double(range.min), double(range.max));
                        read.refuse(key, &message);
                    }
                    value = number_json(number.clamp(range.min, range.max));
                }
            }
        }
        read.set(field, value);
    }
    for (field, key) in [
        ("shadow", "appearance.menu.shadow"),
        ("shortcuts", "appearance.menu.shortcuts"),
        ("sectionLabel", "appearance.menu.sectionLabel"),
        ("separator", "appearance.menu.separator"),
        ("destructiveInk", "appearance.menu.destructiveInk"),
        ("submenu", "appearance.menu.submenu"),
        ("subtitle", "appearance.menu.subtitle"),
        ("popoverHeader", "appearance.popover.header"),
        ("progressFill", "appearance.popover.progressFill"),
    ] {
        read.choice(field, key);
    }
    let key = "appearance.menu.fill";
    let mut fill = Value::Null;
    if let Some(raw) = read.at(key) {
        match raw.as_str().filter(|text| schema::is_hex_color(text)) {
            Some(text) => fill = json!(text),
            None => read.refuse(key, "expected \"#RRGGBB\" or \"#RRGGBBAA\""),
        }
    }
    read.set("fill", fill);
}

const MOTION_CATEGORIES: [&str; 10] = [
    "sidebar",
    "tabs",
    "panes",
    "overlays",
    "hoverCards",
    "home",
    "cursor",
    "indicators",
    "feedback",
    "web",
];

fn motion_categories(read: &mut Read) {
    read.flag("enabled", "ui.animations.enabled");
    let mut disabled = Vec::new();
    for category in MOTION_CATEGORIES {
        let key = format!("ui.animations.{category}");
        let mut on = read.default_of(&key).as_bool().unwrap_or(true);
        match read.at(&key) {
            Some(Value::Bool(flag)) => on = *flag,
            Some(_) => read.refuse(&key, "expected true or false"),
            None => {}
        }
        if !on {
            disabled.push(category);
        }
    }
    read.set("disabled", json!(disabled));
}

const RETIRED_TEMPLATES: [&str; 5] = ["cards", "default", "composer", "threads", "console"];
const ALL_TEMPLATES: [&str; 8] =
    ["minimal", "cards", "default", "composer", "threads", "console", "classic", "terminal"];

fn new_tab_template(read: &mut Read) {
    let key = "tabs.newTabTemplate";
    let mut value = Value::Null;
    if let Some(raw) = read.at(key) {
        match raw.as_str().filter(|text| ALL_TEMPLATES.contains(text)) {
            // A retired template stays readable so an existing config keeps working; it shows Minimal.
            Some(text) if RETIRED_TEMPLATES.contains(&text) => value = json!("minimal"),
            Some(text) => value = json!(text),
            None => {
                let live = ALL_TEMPLATES.iter().filter(|t| !RETIRED_TEMPLATES.contains(t));
                read.refuse(key, &format!("expected one of {}", quoted(live)));
            }
        }
    }
    read.set("template", value);
}

fn now_playing(read: &mut Read) {
    let members = read.object("sidebar.nowPlaying");
    let field = |key: &str| members.and_then(|m| m.get(key)).cloned();
    read.flag_of(field("enabled").as_ref(), "enabled", "sidebar.nowPlaying.enabled");
    read.flag_of(field("otherApps").as_ref(), "otherApps", "sidebar.nowPlaying.otherApps");
    // Read at its own paths: `tabs` and `media` hold other settings' keys.
    read.flag("newTab", "tabs.newTabNowPlaying");
    read.flag("pictureInPicture", "media.pictureInPicture.enabled");
}

fn palette_ranking(read: &mut Read) {
    let mut aliases: std::collections::BTreeMap<String, Vec<String>> =
        std::collections::BTreeMap::new();
    if let Some(Value::Object(members)) = read.at("palette.aliases") {
        let mut sorted: Vec<_> = members.iter().collect();
        sorted.sort_by(|a, b| a.0.cmp(b.0));
        for (alias, value) in sorted {
            let word = alias.trim();
            let Some(id) = value.as_str().filter(|id| !id.is_empty()) else { continue };
            if word.is_empty() {
                continue;
            }
            aliases.entry(id.to_owned()).or_default().push(word.to_owned());
        }
    }
    read.set("aliases", json!(aliases));
    let mut pins = read.default_of("palette.pins");
    if let Some(Value::Array(items)) = read.at("palette.pins") {
        let mut seen = std::collections::BTreeSet::new();
        let list: Vec<&str> = items
            .iter()
            .filter_map(Value::as_str)
            .filter(|pin| !pin.is_empty() && seen.insert(*pin))
            .collect();
        pins = json!(list);
    }
    read.set("pins", pins);
    let mut remembers = read.default_of("palette.searchHistory");
    if let Some(Value::Bool(on)) = read.at("palette.searchHistory") {
        remembers = json!(on);
    }
    read.set("remembersSearches", remembers);
    // Swift ignores a bad `experiments.paletteV2` / `palettePreview` silently.
    let mut look = read.default_of("experiments.paletteV2");
    if let Some(text) = read.at("experiments.paletteV2").and_then(Value::as_str)
        && read.choices_of("experiments.paletteV2").iter().any(|c| c == text)
    {
        look = json!(text);
    }
    read.set("paletteV2", look);
    let mut preview = read.default_of("experiments.palettePreview");
    if let Some(Value::Bool(on)) = read.at("experiments.palettePreview") {
        preview = json!(on);
    }
    read.set("palettePreview", preview);
}

fn palette_scope_prefixes(read: &mut Read) {
    let mut assigned = Map::new();
    for scope in ["tabs", "workspaces", "commands", "settings", "scopes"] {
        let key = format!("palette.scopes.{scope}.prefix");
        let Some(raw) = read.at(&key) else { continue };
        let characters: Vec<String> =
            read.choices_of(&key).into_iter().filter(|c| c != "none").collect();
        match raw.as_str() {
            Some("none") => {
                assigned.insert(scope.to_owned(), Value::Null);
            }
            Some(text) if characters.iter().any(|c| c == text) => {
                assigned.insert(scope.to_owned(), json!(text));
            }
            _ => {
                let message = format!(
                    "expected one punctuation character ({}) or \"none\"",
                    characters.join(" ")
                );
                read.refuse(&key, &message);
            }
        }
    }
    read.set("assigned", Value::Object(assigned));
}

fn remote_localhost(read: &mut Read) {
    let mut enabled = read.default_of("browser.remoteLocalhost");
    let mut overrides = Map::new();
    if let Some(Value::Object(browser)) = read.at("browser") {
        if let Some(raw) = browser.get("remoteLocalhost") {
            match raw {
                Value::Bool(flag) => enabled = json!(flag),
                _ => read.refuse("browser.remoteLocalhost", "expected true or false"),
            }
        }
        match browser.get("remoteLocalhostWorkspaces") {
            None => {}
            Some(Value::Object(entries)) => {
                for (id, entry) in entries {
                    match entry {
                        Value::Bool(flag) => {
                            overrides.insert(id.clone(), json!(flag));
                        }
                        _ => read.refuse(
                            &format!("browser.remoteLocalhostWorkspaces.{id}"),
                            "expected true or false",
                        ),
                    }
                }
            }
            Some(_) => read.refuse(
                "browser.remoteLocalhostWorkspaces",
                "expected an object of workspace id to true or false",
            ),
        }
    }
    read.set("enabled", enabled);
    read.set("workspaceOverrides", Value::Object(overrides));
}

/// `/...` or `~/...`: the folders a list names.
fn is_folder(text: &str) -> bool {
    text.starts_with('/') || text.starts_with("~/")
}

fn screenshots(read: &mut Read, home: &str) {
    read.flag("findTools", "screenshots.findTools");
    let key = "screenshots.folders";
    let mut folders = read.default_of(key);
    if let Some(raw) = read.at(key) {
        match raw.as_array() {
            None => read.refuse(key, "expected an array of folder paths"),
            Some(items) => {
                let mut kept = Vec::new();
                for item in items {
                    match item.as_str().filter(|text| is_folder(text)) {
                        Some(text) => match text.strip_prefix('~') {
                            Some(rest) if text.starts_with("~/") => {
                                kept.push(format!("{home}{rest}"));
                            }
                            _ => kept.push(text.to_owned()),
                        },
                        None => read.refuse(key, "expected an absolute or ~/ path"),
                    }
                }
                folders = json!(kept);
            }
        }
    }
    read.set("folders", folders);
}

fn sessions(read: &mut Read) {
    let members = read.object("sessions");
    let field = |key: &str| members.and_then(|m| m.get(key)).cloned();
    read.choice_of(field("keepAwake").as_ref(), "keepAwake", "sessions.keepAwake");
    for (name, key) in [
        ("keepAwakeForCommands", "keepAwakeForCommands"),
        ("keepsAwakeWhenLocked", "keepAwakeWhenLocked"),
        ("resumesAgents", "resumeAgents"),
        ("allowsFullAccess", "allowFullAccess"),
        ("promptSuggestions", "promptSuggestions"),
    ] {
        read.flag_of(field(key).as_ref(), name, &format!("sessions.{key}"));
    }
    let phone = read.object("phone");
    let field = |key: &str| phone.and_then(|m| m.get(key)).cloned();
    read.choice_of(field("keepAwake").as_ref(), "phoneKeepAwake", "phone.keepAwake");
    read.flag_of(field("cloudReplica").as_ref(), "publishesCloudReplica", "phone.cloudReplica");
    read.flag_of(field("cloudDesktop").as_ref(), "phoneSeesCloudDesktop", "phone.cloudDesktop");
}

const SURFACES: [&str; 14] = [
    "sidebar",
    "tabBar",
    "terminal",
    "agentPane",
    "settings",
    "newTabPage",
    "home",
    "browserChrome",
    "internalPage",
    "splitDivider",
    "docks",
    "diff",
    "markdown",
    "editor",
];

fn surface_backgrounds(read: &mut Read) {
    let root_key = "appearance.surfaces";
    let mut overrides = Map::new();
    if let Some(raw) = read.at(root_key) {
        match raw.as_object() {
            None => read.refuse(root_key, "expected an object"),
            Some(surfaces) => {
                for (name, entry) in surfaces {
                    let path = format!("{root_key}.{name}");
                    if !SURFACES.contains(&name.as_str()) {
                        let message =
                            format!("unknown surface; expected one of {}", quoted(SURFACES));
                        read.refuse(&path, &message);
                        continue;
                    }
                    let Some(fields) = entry.as_object() else {
                        read.refuse(&path, "expected an object");
                        continue;
                    };
                    let mut background = Map::new();
                    for (field, value) in fields {
                        match field.as_str() {
                            "color" => match value.as_str().filter(|t| schema::is_hex_color(t)) {
                                Some(text) => {
                                    background.insert("color".to_owned(), json!(text));
                                }
                                None => read.refuse(
                                    &format!("{path}.color"),
                                    "expected \"#RRGGBB\" or \"#RRGGBBAA\"",
                                ),
                            },
                            "opacity" => {
                                let range =
                                    read.number_range("appearance.surfaces.sidebar.opacity");
                                match value.as_f64().filter(|x| (range.min..=range.max).contains(x))
                                {
                                    Some(number) => {
                                        background
                                            .insert("opacity".to_owned(), number_json(number));
                                    }
                                    None => read.refuse(
                                        &format!("{path}.opacity"),
                                        "expected a number from 0 to 1, such as 0.85",
                                    ),
                                }
                            }
                            other => read.refuse(
                                &format!("{path}.{other}"),
                                "unknown field; expected \"color\" or \"opacity\"",
                            ),
                        }
                    }
                    if !background.is_empty() {
                        overrides.insert(name.clone(), Value::Object(background));
                    }
                }
            }
        }
    }
    read.set("overrides", Value::Object(overrides));
}

fn trust(read: &mut Read) {
    read.flag("autoTrust", "agents.trust.autoTrust");
    for (field, key, shape, item) in [
        (
            "projectRoots",
            "agents.trust.projectRoots",
            "expected an array of folder paths",
            "expected an absolute or ~/ path",
        ),
        (
            "ownOrgs",
            "agents.trust.ownOrgs",
            "expected an array of GitHub user or organization names",
            "expected a non-empty GitHub user or organization name",
        ),
    ] {
        let mut list = read.default_of(key);
        if let Some(raw) = read.at(key) {
            match raw.as_array() {
                None => read.refuse(key, shape),
                Some(items) => {
                    let mut kept = Vec::new();
                    for entry in items {
                        let ok = entry.as_str().filter(|text| {
                            if field == "projectRoots" { is_folder(text) } else { !text.is_empty() }
                        });
                        match ok {
                            Some(text) => kept.push(text.to_owned()),
                            None => read.refuse(key, item),
                        }
                    }
                    list = json!(kept);
                }
            }
        }
        read.set(field, list);
    }
}

fn updates(read: &mut Read) {
    let members = read.object("updates");
    let field = |key: &str| members.and_then(|m| m.get(key)).cloned();
    read.choice_of(field("channel").as_ref(), "channel", "updates.channel");
    // While `updates.automatic` is unset it reads the three toggles it replaced
    // (retired-keys.json), then this build's default.
    let automatic = field("automatic");
    let legacy = automatic
        .is_none()
        .then(|| renamed::legacy_value(&["updates".to_owned(), "automatic".to_owned()], read.root))
        .flatten();
    match legacy {
        Some(old) => read.set("automatic", old),
        None => read.choice_of(automatic.as_ref(), "automatic", "updates.automatic"),
    }
    for (name, key) in [
        ("oneClickInstall", "oneClickInstall"),
        ("whatsNewInstall", "whatsNewInstall"),
        ("installOnQuit", "installOnQuit"),
        ("liveWebReload", "liveWebReload"),
        ("showWhatsNew", "showWhatsNew"),
    ] {
        read.flag_of(field(key).as_ref(), name, &format!("updates.{key}"));
    }
    for (name, key) in [
        ("checkIntervalSeconds", "checkIntervalSeconds"),
        ("installWhenIdleMinutes", "installWhenIdleMinutes"),
        ("keepPreviousVersions", "keepPreviousVersions"),
        ("idleInstallMaxWaitSeconds", "idleInstallMaxWaitSeconds"),
        ("idleInstallQuietSeconds", "idleInstallQuietSeconds"),
    ] {
        read.clamped_of(field(key).as_ref(), name, &format!("updates.{key}"));
    }
    // An older notify value reads as its replacement with no diagnostic.
    let notify = "updates.notify";
    match read.at(notify).and_then(Value::as_str).and_then(|old| schema::choice_alias(notify, old))
    {
        Some(new) => read.set("notify", json!(new)),
        None => read.choice_of(field("notify").as_ref(), "notify", notify),
    }
    read.choice_of(field("meteredNetwork").as_ref(), "meteredNetwork", "updates.meteredNetwork");
    read.choice_of(field("web").as_ref(), "web", "updates.web");
}

fn workspace_hibernation(read: &mut Read) {
    let members = read.object("workspaces.hibernation");
    let field = |key: &str| members.and_then(|m| m.get(key)).cloned();
    read.flag_of(field("enabled").as_ref(), "enabled", "workspaces.hibernation.enabled");
    read.clamped_of(
        field("idleMinutes").as_ref(),
        "idleMinutes",
        "workspaces.hibernation.idleMinutes",
    );
    read.clamped_of(
        field("hiddenSpaceMinutes").as_ref(),
        "hiddenSpaceMinutes",
        "workspaces.hibernation.hiddenSpaceMinutes",
    );
    let freeing = read.object("workspaces.freeing");
    let field = |key: &str| freeing.and_then(|m| m.get(key)).cloned();
    read.flag_of(field("enabled").as_ref(), "freeingEnabled", "workspaces.freeing.enabled");
    read.clamped_of(
        field("idleMinutes").as_ref(),
        "freeingIdleMinutes",
        "workspaces.freeing.idleMinutes",
    );
    read.flag_of(field("agents").as_ref(), "freeingAgents", "workspaces.freeing.agents");
    read.choice_of(
        field("runningCommands").as_ref(),
        "freeingRunningCommands",
        "workspaces.freeing.runningCommands",
    );
}

fn workspace_list(read: &mut Read) {
    read.choice("newWorkspacePlacement", "workspaces.newPlacement");
    read.flag("groupsByComputer", "sidebar.groupByComputer");
    read.flag("autoNamesWorkspaces", "workspaces.autoName");
}

fn appearance_tuning(read: &mut Read) {
    for (field, key, example) in [
        ("glassTransparency", "appearance.glassTransparency", "0.35"),
        ("hue", "appearance.hue", "0.5"),
        ("saturation", "appearance.saturation", "1.25"),
    ] {
        let range = read.number_range(key);
        let mut value = read.default_of(key);
        if let Some(raw) = read.at(key) {
            match raw.as_f64().filter(|x| x.is_finite() && (range.min..=range.max).contains(x)) {
                Some(number) => value = number_json(number),
                None => {
                    let message = format!(
                        "expected a number from {} to {}, such as {example}",
                        double(range.min),
                        double(range.max)
                    );
                    read.refuse(key, &message);
                }
            }
        }
        read.set(field, value);
    }
}

fn auto_archive(read: &mut Read) {
    let members = read.object("workspaces.autoArchive");
    let field = |key: &str| members.and_then(|m| m.get(key)).cloned();
    read.choice_of(field("style").as_ref(), "style", "workspaces.autoArchive.style");
    read.clamped_of(field("idleDays").as_ref(), "idleDays", "workspaces.autoArchive.idleDays");
}

/// Swift `ChatSettings.validate`: a boolean chat key that is not true or false, or a roots list
/// that is not absolute folder paths.
fn chat_diagnostics(read: &mut Read) {
    for key in [
        "agents.chats.enabled",
        "agents.chats.discovery",
        "agents.chats.sessionRecap",
        "agents.chats.terminalChatWritable",
        "agents.chats.roots",
    ] {
        let Some(raw) = read.at(key) else { continue };
        let Some(row) = read.row(key) else { continue };
        if schema::accepts(row, raw, &Domains::default()).is_ok() {
            continue;
        }
        let expected = if key == "agents.chats.roots" {
            "a list of absolute folder paths (starting with / or ~/)"
        } else {
            "true or false"
        };
        read.refuse(key, &format!("expected {expected}"));
    }
}

/// `ReducedBackgroundsSetting.notes`: one note per covered key while Plain Backgrounds is on.
fn reduced_backgrounds_notes(request: &Value, read: &mut Read) {
    if request.get("reduced").and_then(Value::as_bool) != Some(true) {
        return;
    }
    for path in
        ["appearance.backgroundOpacity", "appearance.backgroundBlur", "appearance.background"]
    {
        read.diagnostics.push(json!({
            "kind": "plainBackgrounds",
            "path": path,
            "message": "Plain Backgrounds is on, so windows draw the plain theme color",
        }));
    }
}

// MARK: other ops

fn recent_fonts_recorded(request: &Value) -> Result<Value, OpError> {
    const LIMIT: usize = 6;
    let family = string(request, "family")?.trim();
    let list: Vec<&str> = request
        .get("list")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    if family.is_empty() {
        return Ok(json!({"list": list}));
    }
    let mut result = vec![family];
    result.extend(list.into_iter().filter(|name| *name != family));
    result.truncate(LIMIT);
    Ok(json!({"list": result}))
}

fn feature_tips_is_open(request: &Value) -> Result<Value, OpError> {
    const MINIMUM_DAYS: f64 = 14.0;
    let at = request
        .get("at")
        .and_then(Value::as_f64)
        .ok_or_else(|| OpError::Invalid("expected a number `at`".to_owned()))?;
    let open = match request.get("lastShownAt").and_then(Value::as_f64) {
        None => true,
        Some(last) => at - last >= MINIMUM_DAYS * 86_400.0,
    };
    Ok(json!({"open": open}))
}

#[cfg(test)]
#[path = "custom_tests.rs"]
mod tests;
