//! The viewer toolbar's rules (`MacScreenToolbar.swift`): which bar a look
//! draws, what each control shows and whether it is on, the stats line, the
//! menus' rows and the responsive layout math. Swift measures text (it owns
//! the fonts) and draws; every decision is here. See `ui/mod.rs`.
//!
//! Text comes back as [`Piece`]s: `{"text": "..."}` shown as is, or
//! `{"key": "...", "text": "..."}` localized in Swift as `L.t(key, text)`;
//! `args` (ints) then fill `%d`s with `String(format:)`. A line of pieces
//! joins with `" · "`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{Answer, answer, args};

/// One piece of shown text: `L.t(key, text)` when keyed, else `text`; then `args` fill its `%d`s.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub(crate) struct Piece {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key: Option<&'static str>,
    pub text: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<i64>,
}

impl Piece {
    pub(crate) fn text(text: impl Into<String>) -> Self {
        Self { key: None, text: text.into(), args: Vec::new() }
    }
    pub(crate) fn key(key: &'static str, text: impl Into<String>) -> Self {
        Self { key: Some(key), text: text.into(), args: Vec::new() }
    }
    fn with(mut self, args: Vec<i64>) -> Self {
        self.args = args;
        self
    }
    /// The English the piece shows (tests, and the Swift parity checks).
    #[cfg(test)]
    pub(crate) fn english(&self) -> String {
        let mut out = String::new();
        let mut args = self.args.iter();
        let mut chars = self.text.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '%' && chars.peek() == Some(&'d') {
                chars.next();
                out.push_str(&args.next().map(i64::to_string).unwrap_or_default());
            } else {
                out.push(c);
            }
        }
        out
    }
}

/// A line's pieces as English, joined as the toolbar joins them.
#[cfg(test)]
pub(crate) fn english(line: &[Piece]) -> String {
    line.iter().map(Piece::english).collect::<Vec<_>>().join(" · ")
}

pub(crate) fn handle(name: &str, raw: &Value) -> Answer {
    Some(match name {
        "bar" => args::<BarArgs>(raw).and_then(|a| answer(&bar(&a))),
        "hiddenByLook" => args::<HiddenArgs>(raw).and_then(|a| answer(&hidden_by_look(&a))),
        "title" => args::<TitleArgs>(raw).and_then(|a| answer(&title(&a))),
        "statusInk" => args::<StatusArgs>(raw).and_then(|a| answer(&status_ink(&a))),
        "statsLine" => args::<StatsLineArgs>(raw).and_then(|a| answer(&stats_line(&a))),
        "statsLines" => args::<StatsLinesArgs>(raw).and_then(|a| answer(&stats_lines(&a))),
        "pillLine" => args::<PillArgs>(raw).and_then(|a| answer(&pill_line(&a))),
        "statsMode" => args::<StatsModeArgs>(raw).and_then(|a| answer(&stats_mode(&a))),
        "rateText" => {
            args::<RateArgs>(raw).and_then(|a| answer(&rate_pieces(a.kbps, a.profile.as_deref())))
        }
        "isStrained" => args::<StrainArgs>(raw).and_then(|a| answer(&is_strained(&a))),
        "qualityTitle" => args::<QualityArgs>(raw)
            .and_then(|a| quality_title(&a.quality).and_then(|p| answer(&p))),
        "qualityChip" => {
            args::<ChipArgs>(raw).and_then(|a| quality_chip(&a).and_then(|c| answer(&c)))
        }
        "bitrateTitle" => args::<BitrateArgs>(raw).and_then(|a| answer(&bitrate_title(a.kbps))),
        "access" => args::<AccessArgs>(raw).and_then(|a| answer(&access(a.view_only))),
        "displayTitle" => {
            args::<DisplayTitleArgs>(raw).and_then(|a| answer(&display_title(a.current)))
        }
        "controls" => args::<ControlsArgs>(raw).and_then(|a| answer(&controls(&a))),
        "moreMenu" => args::<MoreArgs>(raw).and_then(|a| answer(&more_menu(&a))),
        "recordMenu" => args::<RecordArgs>(raw).and_then(|a| answer(&record_menu(&a))),
        "qualityMenuHead" => {
            args::<QualityHeadArgs>(raw).and_then(|a| answer(&quality_menu_head(&a)))
        }
        "qualityMenu" => args::<QualityMenuArgs>(raw).and_then(|a| answer(&quality_menu(&a))),
        "displayMenu" => args::<DisplayMenuArgs>(raw).and_then(|a| answer(&display_menu(&a))),
        "controlTitles" => args::<ControlTitlesArgs>(raw).and_then(|a| answer(&control_titles(&a))),
        "controlWidth" => args::<ControlWidthArgs>(raw).and_then(|a| answer(&control_width(&a))),
        "expandedWidth" => args::<ExpandedArgs>(raw).and_then(|a| answer(&expanded_width(&a))),
        "arrange" => args::<ArrangeArgs>(raw).and_then(|a| answer(&arrange(&a))),
        "height" => args::<HeightArgs>(raw).and_then(|a| answer(&height(&a))),
        "headerWidth" => args::<HeaderArgs>(raw).and_then(|a| answer(&header_width(&a))),
        "layout" => args::<LayoutArgs>(raw).and_then(|a| answer(&layout(&a))),
        _ => return None,
    })
}

// MARK: Bar and visibility

/// `MacScreenToolbarBar`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Bar {
    Row,
    Icons,
    Controls,
    Stacked,
}

impl Bar {
    /// The bar keeps to one row.
    pub(crate) fn one_row(self) -> bool {
        self != Bar::Stacked
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BarArgs {
    /// `toolbarPlacement`: "topBar" or "floating".
    placement: String,
    /// `toolbarLayout`: "pill" or another.
    layout: String,
    /// The setting's (or the gallery's) bar.
    bar: Bar,
}

/// A floating bar arranges its controls as the setting says; a docked toolbar or a pill keeps stacked.
fn bar(a: &BarArgs) -> Bar {
    if a.placement == "floating" && a.layout != "pill" { a.bar } else { Bar::Stacked }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HiddenArgs {
    status_strip: bool,
    auto_hidden: bool,
    pill: bool,
    shows_session_controls: bool,
    live: bool,
}

/// Under look B's strip, a faded toolbar, or a pill anywhere but over a live picture.
fn hidden_by_look(a: &HiddenArgs) -> bool {
    if a.status_strip || a.auto_hidden {
        return true;
    }
    a.pill && !(a.shows_session_controls && a.live)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TitleArgs {
    name: String,
    #[serde(default)]
    linked_display_gone: bool,
    run_name: Option<String>,
}

/// The device's name, then the run's name or that its display is gone.
fn title(a: &TitleArgs) -> Vec<Piece> {
    let mut parts = vec![Piece::text(a.name.clone())];
    if a.linked_display_gone {
        parts.push(Piece::key(
            "macScreen.run.displayGone",
            "That run's display is gone; showing the main display",
        ));
    } else if let Some(run) = &a.run_name {
        parts.push(Piece::text(run.clone()));
    }
    parts
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StatusArgs {
    /// The hub viewer's phase name (`requesting`, `streaming`, ...), nil without a hub.
    hub_phase: Option<String>,
    gate_open: bool,
    /// The session's phase: connected, connecting, failed, ended; nil without a session.
    session_phase: Option<String>,
    #[serde(default)]
    reconnecting: bool,
}

/// The status dot's ink: attention, danger, tertiary or success.
fn status_ink(a: &StatusArgs) -> &'static str {
    match a.hub_phase.as_deref() {
        Some("requesting" | "waitingForApproval" | "approved") => return "attention",
        Some("declined" | "refused" | "revoked") => return "danger",
        Some("idle" | "ended") => return "tertiary",
        _ => {}
    }
    let Some(phase) = a.session_phase.as_deref().filter(|_| a.gate_open) else { return "tertiary" };
    match phase {
        "connected" if a.reconnecting => "attention",
        "connected" => "success",
        "connecting" => "attention",
        "failed" => "danger",
        _ => "tertiary",
    }
}

// MARK: Stats

/// `%.0f`: round half to even on the exact value, as printf does.
fn f0(value: f64) -> String {
    format!("{value:.0}")
}

/// `MacScreenQualityReadout.rateText(kbps:)`.
pub(crate) fn rate_text(kbps: f64) -> String {
    if !kbps.is_finite() || kbps <= 0.0 {
        return "0 kbps".into();
    }
    if kbps >= 10_000.0 {
        return format!("{} Mbps", f0(kbps / 1000.0));
    }
    if kbps >= 1000.0 {
        return format!("{:.1} Mbps", kbps / 1000.0);
    }
    format!("{} kbps", f0(kbps))
}

/// The rate with `Ultra` before it for an ultra session (two pieces of the line).
pub(crate) fn rate_pieces(kbps: f64, profile: Option<&str>) -> Vec<Piece> {
    let mut out = Vec::new();
    if profile == Some("ultra") {
        out.push(Piece::key("macScreen.readout.ultra", "Ultra"));
    }
    out.push(Piece::text(rate_text(kbps)));
    out
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RateArgs {
    kbps: f64,
    profile: Option<String>,
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StatsLineArgs {
    pub path: String,
    pub kbps: Option<f64>,
    pub profile: Option<String>,
    pub fps: f64,
    pub target_fps: Option<i64>,
    pub latency_ms: Option<f64>,
    pub encoding: String,
    #[serde(default)]
    pub frame_width: f64,
    #[serde(default)]
    pub frame_height: f64,
}

/// Path, the host's rate, the frame rate (measured, then the agreed one), round trip, codec, size.
pub(crate) fn stats_line(a: &StatsLineArgs) -> Vec<Piece> {
    let measured = if a.fps.is_finite() { a.fps.round() as i64 } else { 0 };
    let mut parts = vec![Piece::text(a.path.clone())];
    if let Some(kbps) = a.kbps {
        parts.extend(rate_pieces(kbps, a.profile.as_deref()));
    }
    parts.push(match a.target_fps {
        Some(target) => {
            Piece::key("macScreen.stats.fpsOfTarget", format!("{measured}/{target} fps"))
        }
        None => Piece::text(format!("{} fps", f0(a.fps))),
    });
    if let Some(rtt) = a.latency_ms {
        parts.push(Piece::text(format!("{} ms", f0(rtt))));
    }
    if a.encoding != "-" {
        parts.push(Piece::text(a.encoding.clone()));
    }
    if a.frame_width >= 1.0 {
        parts.push(Piece::text(format!("{}×{}", a.frame_width as i64, a.frame_height as i64)));
    }
    parts
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StatsLinesArgs {
    #[serde(flatten)]
    line: StatsLineArgs,
    /// The inline readout: the line leads with the host's rate (`line.kbps` is the host's).
    #[serde(default)]
    rate: bool,
}

#[derive(Serialize)]
struct StatsLines {
    full: Vec<Piece>,
    /// No codec and no size.
    short: Vec<Piece>,
    /// Every number at three digits: Swift measures it with `full` and keeps the wider as the room.
    widest: Vec<Piece>,
}

fn stats_lines(a: &StatsLinesArgs) -> StatsLines {
    let mut line = a.line.clone();
    if !a.rate {
        line.kbps = None;
    }
    let short =
        StatsLineArgs { encoding: "-".into(), frame_width: 0.0, frame_height: 0.0, ..line.clone() };
    let widest = StatsLineArgs {
        kbps: line.kbps.map(|_| 888_000.0),
        fps: 888.0,
        target_fps: line.target_fps.map(|_| 888),
        latency_ms: Some(888.0),
        ..line.clone()
    };
    StatsLines { full: stats_line(&line), short: stats_line(&short), widest: stats_line(&widest) }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PillArgs {
    latency_ms: Option<f64>,
    host_kbps: Option<f64>,
    profile: Option<String>,
}

/// The pill's readout: the host's rate and the round trip; the round trip alone until a rate.
fn pill_line(a: &PillArgs) -> Vec<Piece> {
    let latency = Piece::text(
        a.latency_ms.map(|ms| format!("{} ms", f0(ms))).unwrap_or_else(|| "— ms".into()),
    );
    let Some(kbps) = a.host_kbps else { return vec![latency] };
    let mut out = rate_pieces(kbps, a.profile.as_deref());
    out.push(latency);
    out
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StatsModeArgs {
    show_stats: bool,
    pill: bool,
    quiet_outage: bool,
    /// The quality readout is `inline`.
    inline: bool,
}

/// What the stats slot says: `lines` (``statsLines``), `reconnecting`, `pill` (``pillLine``) or `latency`.
fn stats_mode(a: &StatsModeArgs) -> &'static str {
    if a.show_stats && !a.pill {
        "lines"
    } else if a.pill && a.quiet_outage {
        "reconnecting"
    } else if a.inline {
        "pill"
    } else {
        "latency"
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StrainArgs {
    loss_percent: Option<f64>,
    fps: f64,
    target_fps: Option<i64>,
}

/// The host loses more than 5%, or the picture runs under half its agreed rate.
fn is_strained(a: &StrainArgs) -> bool {
    if a.loss_percent.is_some_and(|loss| loss > 5.0) {
        return true;
    }
    matches!(a.target_fps, Some(target) if target > 0 && a.fps > 0.0 && a.fps < target as f64 / 2.0)
}

// MARK: Quality, bitrate, access

pub(crate) const QUALITIES: [&str; 5] = ["auto", "smooth", "low", "medium", "high"];

#[derive(Deserialize)]
struct QualityArgs {
    quality: String,
}

pub(crate) fn quality_title(quality: &str) -> Result<Piece, String> {
    Ok(match quality {
        "auto" => Piece::key("macScreen.quality.auto", "Auto"),
        "smooth" => Piece::key("macScreen.quality.smooth", "Smooth Motion"),
        "low" => Piece::key("macScreen.quality.low", "Fixed Low (720p)"),
        "medium" => Piece::key("macScreen.quality.medium", "Fixed Medium (1080p)"),
        "high" => Piece::key("macScreen.quality.high", "Fixed High (Full)"),
        other => return Err(format!("unknown quality {other}")),
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChipArgs {
    bar: Bar,
    /// `MacScreenQualityReadout`: "chip", "inline", ...
    readout: String,
    live: bool,
    host_kbps: Option<f64>,
    profile: Option<String>,
    quality: String,
    loss_percent: Option<f64>,
    #[serde(default)]
    fps: f64,
    target_fps: Option<i64>,
}

#[derive(Serialize)]
struct Chip {
    /// The Quality button's title (empty: the glyph alone).
    title: Vec<Piece>,
    ink: &'static str,
}

/// The Quality button: the rate while live where the bar says it (attention when the stream strains),
/// else the quality's name; a one-row bar never says "Auto".
fn quality_chip(a: &ChipArgs) -> Result<Chip, String> {
    let rated = matches!(a.bar, Bar::Row | Bar::Controls) || a.readout == "chip";
    let chip = if rated && a.bar != Bar::Icons && a.live { a.host_kbps } else { None };
    let title = match chip {
        Some(kbps) => rate_pieces(kbps, a.profile.as_deref()),
        None if a.bar.one_row() => Vec::new(),
        None => vec![quality_title(&a.quality)?],
    };
    let strained = is_strained(&StrainArgs {
        loss_percent: a.loss_percent,
        fps: a.fps,
        target_fps: a.target_fps,
    });
    Ok(Chip { title, ink: if chip.is_some() && strained { "attention" } else { "secondary" } })
}

#[derive(Deserialize)]
struct BitrateArgs {
    kbps: Option<i64>,
}

fn bitrate_title(kbps: Option<i64>) -> Piece {
    match kbps {
        None => Piece::key("macScreen.customize.bitrateAuto", "Auto"),
        Some(kbps) => {
            Piece::key("macScreen.customize.bitrateMbps", "%d Mbps").with(vec![kbps / 1000])
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AccessArgs {
    view_only: bool,
}

#[derive(Serialize)]
struct Access {
    title: Piece,
    symbol: &'static str,
    ink: &'static str,
    /// The View | Control segment selected.
    segment: &'static str,
}

fn access(view_only: bool) -> Access {
    if view_only {
        Access {
            title: Piece::key("macScreen.scope.view", "View Only"),
            symbol: "eye",
            ink: "attention",
            segment: "view",
        }
    } else {
        Access {
            title: Piece::key("macScreen.scope.full", "Full Control"),
            symbol: "cursorarrow",
            ink: "secondary",
            segment: "full",
        }
    }
}

#[derive(Deserialize)]
struct DisplayTitleArgs {
    current: i64,
}

fn display_title(current: i64) -> Piece {
    Piece::key("macScreen.toolbar.displayShort", "Display %d").with(vec![current + 1])
}

// MARK: Controls

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct Recording {
    is_recording: bool,
    can_record: bool,
    has_last_file: bool,
    failed: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ControlsArgs {
    /// `showsSessionControls`.
    controls_shown: bool,
    pill: bool,
    bar: Bar,
    live: bool,
    /// The session ended or failed.
    ended: bool,
    view_only: bool,
    can_send_keys: bool,
    display_count: i64,
    /// The look draws View | Control segments in place of the access menu.
    scope_segments: bool,
    capture_keyboard: bool,
    has_session: bool,
    #[serde(default)]
    recording: Recording,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Controls {
    stats_slot: bool,
    hint_slot: bool,
    segments_show_titles: bool,
    /// The dot's tooltip is the title (the controls-only bar shows no name).
    dot_tip_is_title: bool,
    access_hidden: bool,
    segments_hidden: bool,
    access_enabled: bool,
    full_screen_hidden: bool,
    more_hidden: bool,
    display_hidden: bool,
    quality_hidden: bool,
    send_keys_hidden: bool,
    send_keys_enabled: bool,
    send_keys_ink: &'static str,
    send_keys_tip: Piece,
    record_hidden: bool,
    record_enabled: bool,
    record_active: bool,
    record_symbol: &'static str,
    record_ink: &'static str,
    record_tip: Piece,
    refresh_hidden: bool,
    refresh_enabled: bool,
    connect_hidden: bool,
    disconnect_hidden: bool,
    disconnect_glyph_hidden: bool,
}

/// What each toolbar control shows and whether it takes a click (`apply()`, `applyRecord`).
fn controls(a: &ControlsArgs) -> Controls {
    let shown = a.controls_shown;
    let r = &a.recording;
    let active = r.is_recording;
    Controls {
        stats_slot: a.has_session && a.live,
        hint_slot: a.capture_keyboard && a.live,
        segments_show_titles: a.bar != Bar::Icons,
        dot_tip_is_title: a.bar == Bar::Controls,
        access_hidden: !shown || a.scope_segments,
        segments_hidden: !shown || !a.scope_segments,
        access_enabled: shown,
        full_screen_hidden: !shown || a.pill,
        more_hidden: !shown,
        display_hidden: !shown || a.display_count <= 1 || a.pill,
        quality_hidden: !shown,
        send_keys_hidden: !shown || a.pill || a.bar.one_row(),
        send_keys_enabled: a.can_send_keys,
        send_keys_ink: if a.can_send_keys { "secondary" } else { "tertiary" },
        send_keys_tip: if a.view_only {
            Piece::key(
                "macScreen.toolbar.sendKeysViewOnly",
                "Send Keys is off in a View Only session",
            )
        } else {
            Piece::key("macScreen.toolbar.sendKeys", "Send Keys")
        },
        record_hidden: !shown,
        record_enabled: active || (a.live && r.can_record) || r.has_last_file,
        record_active: active,
        record_symbol: if active { "record.circle.fill" } else { "record.circle" },
        record_ink: if active { "danger" } else { "secondary" },
        record_tip: if r.failed {
            Piece::key("macScreen.record.failed", "The recording could not be saved")
        } else if active {
            Piece::key("macScreen.record.stop", "Stop Recording")
        } else {
            Piece::key("macScreen.record.title", "Record Screen")
        },
        refresh_hidden: !shown || a.pill || a.bar.one_row(),
        refresh_enabled: a.live,
        connect_hidden: !shown || !a.ended,
        disconnect_hidden: !shown || a.ended || a.bar == Bar::Icons,
        disconnect_glyph_hidden: !shown || a.ended || a.bar != Bar::Icons,
    }
}

// MARK: Menus

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct MenuRow {
    /// What the row is: Swift wires the action (and a submenu) by it.
    id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<Piece>,
    enabled: bool,
    checked: bool,
}

impl MenuRow {
    fn new(id: &str, title: Option<Piece>, enabled: bool) -> Self {
        Self { id: id.into(), title, enabled, checked: false }
    }
    fn separator() -> Self {
        Self::new("separator", None, true)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MoreArgs {
    display_count: i64,
    can_send_keys: bool,
    live: bool,
    /// The Record button is hidden (a compact bar folds it into More).
    record_hidden: bool,
    pill: bool,
}

/// More's rows: Displays (submenu, its title the display button's), Send Keys (submenu), Refresh,
/// Record (submenu) when the bar hides it, and the pill's Full Screen (its title the button's).
fn more_menu(a: &MoreArgs) -> Vec<MenuRow> {
    let mut rows = Vec::new();
    if a.display_count > 1 {
        rows.push(MenuRow::new("displays", None, true));
    }
    rows.push(MenuRow::new(
        "sendKeys",
        Some(Piece::key("macScreen.toolbar.sendKeys", "Send Keys")),
        a.can_send_keys,
    ));
    rows.push(MenuRow::new(
        "refresh",
        Some(Piece::key("macScreen.toolbar.refresh", "Refresh Screen")),
        a.live,
    ));
    if a.record_hidden {
        rows.push(MenuRow::new(
            "record",
            Some(Piece::key("macScreen.record.title", "Record Screen")),
            true,
        ));
    }
    if a.pill {
        rows.push(MenuRow::separator());
        rows.push(MenuRow::new("fullScreen", None, true));
    }
    rows
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecordArgs {
    is_recording: bool,
    can_record: bool,
    live: bool,
    has_file: bool,
    has_last_file: bool,
}

fn record_menu(a: &RecordArgs) -> Vec<MenuRow> {
    let toggle = if a.is_recording {
        Piece::key("macScreen.record.stop", "Stop Recording")
    } else {
        Piece::key("macScreen.record.start", "Start Recording")
    };
    vec![
        MenuRow::new("toggleRecording", Some(toggle), a.is_recording || (a.live && a.can_record)),
        MenuRow::new(
            "showRecording",
            Some(Piece::key("macScreen.record.showInFinder", "Show Recording in Finder")),
            a.has_file || a.has_last_file,
        ),
    ]
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct QualityHeadArgs {
    readout: String,
    live: bool,
    connected: bool,
}

/// What heads the Quality menu: `readout` (every number), `stats` (the whole stats line) or `none`.
fn quality_menu_head(a: &QualityHeadArgs) -> &'static str {
    if a.readout == "chip" && a.live {
        "readout"
    } else if a.connected {
        "stats"
    } else {
        "none"
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct QualityMenuArgs {
    quality: String,
    show_stats: bool,
    max_kbps: Option<i64>,
    /// `ScreenPreferences.maxKbpsChoices` (nil: Auto).
    max_kbps_choices: Vec<Option<i64>>,
    show_cursor_in_stream: bool,
}

/// The Quality menu below its head: each quality, Show Stats, then Customize (the bitrate caps, the cursor).
/// Ids: `quality:<name>`, `showStats`, `customize` (section header), `bitrate` (submenu of `cap:<kbps|auto>`), `showCursor`.
fn quality_menu(a: &QualityMenuArgs) -> Vec<Value> {
    let mut rows = Vec::new();
    let row = |row: MenuRow| serde_json::to_value(row).unwrap_or(Value::Null);
    for q in QUALITIES {
        if let Ok(title) = quality_title(q) {
            rows.push(row(MenuRow {
                checked: a.quality == q,
                ..MenuRow::new(&format!("quality:{q}"), Some(title), true)
            }));
        }
    }
    rows.push(row(MenuRow::separator()));
    rows.push(row(MenuRow {
        checked: a.show_stats,
        ..MenuRow::new(
            "showStats",
            Some(Piece::key("macScreen.toolbar.showStats", "Show Stats")),
            true,
        )
    }));
    rows.push(row(MenuRow::separator()));
    rows.push(row(MenuRow::new(
        "customize",
        Some(Piece::key("macScreen.customize.title", "Customize")),
        true,
    )));
    let caps: Vec<Value> = a
        .max_kbps_choices
        .iter()
        .map(|kbps| {
            let id = format!("cap:{}", kbps.map_or("auto".into(), |k| k.to_string()));
            row(MenuRow {
                checked: a.max_kbps == *kbps,
                ..MenuRow::new(&id, Some(bitrate_title(*kbps)), true)
            })
        })
        .collect();
    let mut bitrate = row(MenuRow::new(
        "bitrate",
        Some(Piece::key("macScreen.customize.bitrate", "Bitrate Cap")),
        true,
    ));
    if let Value::Object(map) = &mut bitrate {
        map.insert("submenu".into(), Value::Array(caps));
    }
    rows.push(bitrate);
    rows.push(row(MenuRow {
        checked: a.show_cursor_in_stream,
        ..MenuRow::new(
            "showCursor",
            Some(Piece::key("macScreen.customize.showCursor", "Show Cursor in Stream")),
            true,
        )
    }));
    rows
}

#[derive(Deserialize)]
struct Size {
    width: f64,
    height: f64,
}

#[derive(Deserialize)]
struct DisplayMenuArgs {
    displays: Vec<Size>,
    current: i64,
}

/// One row per display, `display:<index>`, the current one checked.
fn display_menu(a: &DisplayMenuArgs) -> Vec<MenuRow> {
    a.displays
        .iter()
        .enumerate()
        .map(|(index, size)| {
            let title = Piece::key("macScreen.toolbar.display", "Display %d (%d × %d)").with(vec![
                index as i64 + 1,
                size.width as i64,
                size.height as i64,
            ]);
            MenuRow {
                checked: a.current == index as i64,
                ..MenuRow::new(&format!("display:{index}"), Some(title), true)
            }
        })
        .collect()
}

// MARK: Layout

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ControlTitlesArgs {
    /// "access", "quality" or another control.
    control: String,
    bar: Bar,
    /// The Quality button shows a word (a one-row bar's is a glyph until the rate shows).
    #[serde(default)]
    quality_has_title: bool,
    profile: Option<String>,
}

/// The titles a control reserves room for (its longest wins), or `null`: its own fitting width.
/// Choosing access or quality then never moves the responsive breakpoint.
fn control_titles(a: &ControlTitlesArgs) -> Option<Vec<Vec<Piece>>> {
    match a.control.as_str() {
        "access" => Some(vec![
            vec![Piece::key("macScreen.scope.view", "View Only")],
            vec![Piece::key("macScreen.scope.full", "Full Control")],
        ]),
        "quality" if a.bar.one_row() => {
            if !a.quality_has_title {
                return None;
            }
            Some(vec![rate_pieces(888_000.0, a.profile.as_deref())])
        }
        "quality" => {
            Some(QUALITIES.iter().filter_map(|q| quality_title(q).ok()).map(|p| vec![p]).collect())
        }
        _ => None,
    }
}

/// `{space2, space3, space6}` of `Metrics` at the density now.
#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Space {
    pub space2: f64,
    pub space3: f64,
    pub space6: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ControlWidthArgs {
    /// The measured widths of ``controlTitles`` in the body font.
    text_widths: Vec<f64>,
    space: Space,
}

fn control_width(a: &ControlWidthArgs) -> f64 {
    let text = a.text_widths.iter().copied().fold(0.0, f64::max);
    (text + a.space.space6 + a.space.space2).ceil()
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExpandedArgs {
    /// The stacked bar's controls' widths: scope, display (only with more than one display), quality,
    /// send keys, record, refresh, full screen, connect, disconnect.
    widths: Vec<f64>,
    space: Space,
}

/// The stacked bar's width at which every control fits beside the header.
fn expanded_width(a: &ExpandedArgs) -> f64 {
    a.widths.iter().fold(a.space.space6 * 2.0 * 9.0, |total, w| total + w + a.space.space2)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ArrangeArgs {
    width: f64,
    pill: bool,
    bar: Bar,
    controls_shown: bool,
    expanded_width: f64,
    one_row_width: f64,
    display_count: i64,
    space: Space,
    /// Every control's hidden state now, by id (scope, display, quality, sendKeys, record, refresh,
    /// fullScreen, more, connect, disconnect, disconnectGlyph, access).
    hidden: std::collections::BTreeMap<String, bool>,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Arranged {
    /// Hidden states to set before the layout (only the ones this arrangement decides).
    set: std::collections::BTreeMap<&'static str, bool>,
    /// The shown controls in order.
    order: Vec<String>,
}

/// Which controls a width shows and in what order (`arrangedControls(for:)`): the pill's own set, a
/// one-row bar's (the display picker goes to More first when narrow), or the stacked bar's (compact
/// folds the display picker, Send Keys, Refresh and Record into More).
fn arrange(a: &ArrangeArgs) -> Arranged {
    let shown = a.controls_shown;
    let mut set = std::collections::BTreeMap::new();
    let order: &[&str] = if a.pill {
        set.insert("more", !shown);
        &["access", "quality", "record", "more", "connect", "disconnect"]
    } else if a.bar.one_row() {
        set.insert("sendKeys", true);
        set.insert("refresh", true);
        set.insert("more", !shown);
        set.insert("display", !shown || a.display_count <= 1 || a.width < a.one_row_width);
        &[
            "scope",
            "display",
            "quality",
            "fullScreen",
            "more",
            "connect",
            "disconnect",
            "disconnectGlyph",
        ]
    } else {
        let compact = shown && a.width < a.expanded_width - a.space.space6 * 2.0 * 4.0;
        set.insert("display", !shown || a.display_count <= 1 || compact);
        set.insert("sendKeys", !shown || compact);
        set.insert("refresh", !shown || compact);
        set.insert("record", !shown || compact);
        set.insert("more", !shown || !compact);
        &[
            "scope",
            "display",
            "quality",
            "sendKeys",
            "record",
            "refresh",
            "fullScreen",
            "more",
            "connect",
            "disconnect",
        ]
    };
    let hidden =
        |id: &str| set.get(id).copied().or_else(|| a.hidden.get(id).copied()).unwrap_or(false);
    let order = order.iter().filter(|id| !hidden(id)).map(|id| id.to_string()).collect();
    Arranged { set, order }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HeightArgs {
    width: f64,
    /// The look's row height, else `max(space6 * 2, access height + space2)` (Swift measures it).
    row_height: f64,
    controls_shown: bool,
    expanded_width: f64,
    pill: bool,
    bar: Bar,
    /// The arranged controls' widths at `width` (``arrange``, then each measured).
    widths: Vec<f64>,
    space: Space,
}

/// One row, or the header row plus as many rows as the controls wrap into under it.
fn height(a: &HeightArgs) -> f64 {
    if !(a.controls_shown && a.width < a.expanded_width && !a.pill && !a.bar.one_row()) {
        return a.row_height;
    }
    let available = (a.width - a.space.space3 * 2.0).max(0.0);
    let mut rows = 1;
    let mut used = 0.0;
    for w in &a.widths {
        let size = available.min(*w);
        if used > 0.0 && used + size > available {
            rows += 1;
            used = 0.0;
        }
        used += size + a.space.space2;
    }
    a.row_height * (rows + 1) as f64
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HeaderArgs {
    /// "pill", "floating" or "oneRow".
    kind: String,
    bar: Bar,
    space: Space,
    /// The body font's point size (the name's room is at most 16 of it).
    body_point_size: f64,
    icon_width: f64,
    name_width: f64,
    stats_slot: bool,
    /// The stats' room: the pill's widest of its text and the room line (+4), else ``statsLines``' room or the text's.
    stats_room: f64,
    hint_slot: bool,
    hint_width: f64,
    /// The controls' measured widths: the pill's shown ones, or the one-row bar's (display only with more than one).
    controls: Vec<f64>,
    /// For `floating`: ``expandedWidth``.
    #[serde(default)]
    expanded_width: f64,
}

/// A pill's, a floating bar's or a one-row bar's whole width: header (padding, dot, icon, name capped at
/// 16 ems, stats, hint) and controls. A floating bar adds what its header needs past the fixed allowance.
fn header_width(a: &HeaderArgs) -> f64 {
    let gap = a.space.space2;
    let name_room = a.name_width.min((a.body_point_size * 16.0).ceil());
    let stats_room = if a.stats_slot { a.stats_room + gap } else { 0.0 };
    let hint_room = if a.hint_slot { a.hint_width + gap } else { 0.0 };
    let lead = a.space.space3 * 2.0 + a.space.space2 + gap;
    let full_header = lead + a.icon_width + gap + name_room + gap + stats_room + hint_room;
    let controls: f64 = a.controls.iter().map(|w| w + gap).sum();
    match a.kind.as_str() {
        "floating" => {
            let allowance = a.space.space6 * 2.0 * 8.0;
            (a.expanded_width + (full_header - allowance).max(0.0)).ceil()
        }
        "oneRow" if a.bar == Bar::Controls => (lead + controls).ceil(),
        _ => (full_header + controls).ceil(),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LayoutArgs {
    width: f64,
    row_height: f64,
    pill: bool,
    bar: Bar,
    controls_shown: bool,
    expanded_width: f64,
    one_row_width: f64,
    space: Space,
    icon_width: f64,
    name_width: f64,
    /// The stats text's width now (no ``statsLines``), or nil.
    stats_width: Option<f64>,
    /// ``statsLines``' full and short widths in the stats font (the layout picks one).
    stats_full_width: Option<f64>,
    stats_short_width: Option<f64>,
    stats_slot: bool,
    starter_slot: bool,
    starter_width: f64,
    hint_slot: bool,
    hint_width: f64,
    /// The arranged controls' measured widths, in order.
    controls: Vec<f64>,
}

#[derive(Serialize, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
struct Slot {
    x: f64,
    /// The row's top (Swift centres the view's own height in `rowHeight`).
    y: f64,
    width: f64,
}

#[derive(Serialize, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
struct Layout {
    stacked: bool,
    compact: bool,
    /// The dot's square: x, y and its side (`space2`).
    dot: Slot,
    icon_hidden: bool,
    name_hidden: bool,
    stats_hidden: bool,
    starter_hidden: bool,
    hint_hidden: bool,
    /// "full" or "short" when ``statsLines`` are set: the line to show.
    #[serde(skip_serializing_if = "Option::is_none")]
    stats_line: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    icon: Option<Slot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<Slot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    starter: Option<Slot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    stats: Option<Slot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    hint: Option<Slot>,
    controls: Vec<Slot>,
}

/// `layout()`: the header left to right (dot, icon, name, starter, stats, hint), the controls on the
/// right, or wrapped in rows under the header when the stacked bar is narrower than ``expandedWidth``.
fn layout(a: &LayoutArgs) -> Layout {
    let gap = a.space.space2;
    let padding = a.space.space3;
    let width = a.width;
    let bare = a.bar == Bar::Controls;
    let stacked = !a.pill && !a.bar.one_row() && a.controls_shown && width < a.expanded_width;
    let compact = stacked && width < a.expanded_width - a.space.space6 * 2.0 * 4.0;
    let controls_width =
        a.controls.iter().sum::<f64>() + gap * (a.controls.len().max(1) - 1) as f64;
    let header_right =
        if stacked { width - padding } else { width - padding - controls_width - gap };
    let mut out = Layout { stacked, compact, ..Layout::default() };
    let mut x = padding;
    out.dot = Slot { x, y: (a.row_height - a.space.space2) / 2.0, width: a.space.space2 };
    x += a.space.space2 + gap;
    let place = |x: &mut f64, width: f64, y: f64| {
        let slot = Slot { x: *x, y, width: width.max(0.0) };
        *x += width + gap;
        slot
    };
    out.icon_hidden = compact || bare || (a.bar.one_row() && width < a.one_row_width);
    if !out.icon_hidden {
        out.icon = Some(place(&mut x, a.icon_width, 0.0));
    }
    let mut stats_text_width = a.stats_width.unwrap_or(0.0);
    if let (Some(full), Some(short)) = (a.stats_full_width, a.stats_short_width) {
        let fits = full + gap + a.name_width <= header_right - x;
        out.stats_line = Some(if fits { "full" } else { "short" });
        stats_text_width = if fits { full } else { short };
    }
    let name_floor = a.name_width.min(((header_right - x) / 2.0).max(0.0));
    let stats_width = stats_text_width.min((header_right - x - name_floor - gap).max(0.0));
    out.stats_hidden = !a.stats_slot || bare;
    out.name_hidden = bare;
    let mut remaining =
        (header_right - x - if a.stats_slot { stats_width + gap } else { 0.0 }).max(0.0);
    out.starter_hidden =
        !a.starter_slot || bare || remaining < a.name_width + gap + a.starter_width;
    if !out.starter_hidden {
        remaining -= a.starter_width + gap;
    }
    out.hint_hidden = !a.hint_slot || bare || remaining < a.name_width + gap + a.hint_width;
    let name_width = (remaining - if out.hint_hidden { 0.0 } else { a.hint_width + gap }).max(0.0);
    if !bare {
        out.name = Some(place(&mut x, name_width, 0.0));
    }
    if !out.starter_hidden {
        out.starter = Some(place(&mut x, a.starter_width, 0.0));
    }
    if a.stats_slot && !bare {
        out.stats = Some(place(&mut x, stats_width, 0.0));
    }
    if !out.hint_hidden {
        out.hint = Some(place(&mut x, a.hint_width, 0.0));
    }
    x = if stacked { padding } else { width - padding - controls_width };
    let mut y = if stacked { a.row_height } else { 0.0 };
    for measured in &a.controls {
        let w = measured.min((width - padding * 2.0).max(0.0));
        if stacked && x > padding && x + w > width - padding {
            x = padding;
            y += a.row_height;
        }
        out.controls.push(place(&mut x, w, y));
    }
    out
}

#[cfg(test)]
#[path = "toolbar_tests.rs"]
mod tests;
