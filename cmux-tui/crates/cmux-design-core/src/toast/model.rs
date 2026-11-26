//! The toast's value types and their tables: CmuxToast, CmuxToastStack, CmuxToastStyle and
//! CmuxToastLook, CmuxToastTone, CmuxToastGlass, CmuxToastButtonRow, CmuxToastTuning,
//! CmuxToastTunables, CmuxToastStrings, the overlay anchors, the view's numbers, the motion, the
//! playground focus and samples, SurfaceZoomIndicator.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

// MARK: Tone

/// CmuxToastTone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToastTone {
    Neutral,
    Success,
    Warning,
    Error,
    Working,
}

impl ToastTone {
    pub const ALL: [ToastTone; 5] =
        [Self::Neutral, Self::Success, Self::Warning, Self::Error, Self::Working];

    /// The SF Symbol the icon draws.
    pub fn symbol_name(self) -> &'static str {
        match self {
            Self::Neutral | Self::Working => "info.circle.fill",
            Self::Success => "checkmark.circle.fill",
            Self::Warning => "exclamationmark.triangle.fill",
            Self::Error => "xmark.octagon.fill",
        }
    }

    /// The theme token the icon and accent bar take (ThemeTokens member name).
    pub fn color(self) -> &'static str {
        match self {
            Self::Neutral | Self::Working => "accentFill",
            Self::Success => "success",
            Self::Warning => "attention",
            Self::Error => "danger",
        }
    }
}

// MARK: Look

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToastShape {
    Rounded,
    Capsule,
}

/// CmuxToastEntrance.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToastEntrance {
    Rise,
    Pop,
    Slide,
}

/// CmuxToastPlacement.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToastPlacement {
    BottomCenter,
    BottomTrailing,
}

/// CmuxToastDismissReason.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DismissReason {
    Timeout,
    Closed,
    Replaced,
    Action,
}

/// The look's corner: concentric with the buttons, a fixed radius, or a surface role's.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "value")]
pub enum ToastCorner {
    Concentric,
    Points(f64),
    SurfaceRole(String),
}

impl Eq for ToastCorner {}

impl std::hash::Hash for ToastCorner {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        match self {
            Self::Concentric => 0u8.hash(state),
            Self::Points(p) => {
                1u8.hash(state);
                p.to_bits().hash(state);
            }
            Self::SurfaceRole(r) => {
                2u8.hash(state);
                r.hash(state);
            }
        }
    }
}

impl ToastCorner {
    pub const DEFAULT: ToastCorner = ToastCorner::Points(12.0);
}

/// CmuxToastLook: what a style draws.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToastLook {
    pub shape: ToastShape,
    pub glass: Option<ToastGlass>,
    pub placement: ToastPlacement,
    pub entrance: ToastEntrance,
    pub corner: ToastCorner,
    pub compact: bool,
    pub shows_icon: bool,
    pub shows_detail_line: bool,
    pub fills_action: bool,
    pub close_on_hover: bool,
    pub shows_countdown: bool,
    pub accent_bar: bool,
    pub solid: bool,
    pub flat: bool,
    pub marks_tone: bool,
    pub ink_action: bool,
}

impl Default for ToastLook {
    fn default() -> Self {
        Self {
            shape: ToastShape::Rounded,
            glass: None,
            placement: ToastPlacement::BottomCenter,
            entrance: ToastEntrance::Rise,
            corner: ToastCorner::DEFAULT,
            compact: false,
            shows_icon: false,
            shows_detail_line: false,
            fills_action: false,
            close_on_hover: false,
            shows_countdown: false,
            accent_bar: false,
            solid: false,
            flat: false,
            marks_tone: false,
            ink_action: false,
        }
    }
}

// MARK: Style

/// CmuxToastStyle (raw values are the Swift ones).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToastStyle {
    Standard,
    Capsule,
    Compact,
    IconCard,
    FilledAction,
    HoverClose,
    ProgressRing,
    Trailing,
    AccentTinted,
    Solid,
    Flat,
    V2,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToastStyleInfo {
    pub raw_value: &'static str,
    pub title: &'static str,
    pub summary: &'static str,
    pub look: ToastLook,
}

impl ToastStyle {
    pub const ALL: [ToastStyle; 12] = [
        Self::Standard,
        Self::Capsule,
        Self::Compact,
        Self::IconCard,
        Self::FilledAction,
        Self::HoverClose,
        Self::ProgressRing,
        Self::Trailing,
        Self::AccentTinted,
        Self::Solid,
        Self::Flat,
        Self::V2,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Standard => "standard",
            Self::Capsule => "capsule",
            Self::Compact => "compact",
            Self::IconCard => "iconCard",
            Self::FilledAction => "filledAction",
            Self::HoverClose => "hoverClose",
            Self::ProgressRing => "progressRing",
            Self::Trailing => "trailing",
            Self::AccentTinted => "accentTinted",
            Self::Solid => "solid",
            Self::Flat => "flat",
            Self::V2 => "v2",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|s| s.raw_value() == raw)
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Standard => "Standard (today)",
            Self::Capsule => "Liquid Glass capsule",
            Self::Compact => "Compact one-line",
            Self::IconCard => "Two lines with icon",
            Self::FilledAction => "Filled action button",
            Self::HoverClose => "Close on hover",
            Self::ProgressRing => "Countdown ring",
            Self::Trailing => "Bottom trailing",
            Self::AccentTinted => "Accent bar",
            Self::Solid => "Solid, no glass",
            Self::Flat => "Flat",
            Self::V2 => "Toasts v2: mark and ink Undo",
        }
    }

    pub fn summary(self) -> &'static str {
        match self {
            Self::Standard => {
                "Today's toast: veil-tinted glass, rounded corners, text action, rises from the bottom."
            }
            Self::Capsule => {
                "Clear Liquid Glass pill with round ends; grows in from 95% about its center."
            }
            Self::Compact => {
                "Caption-size text and tight padding: the least room a toast can take."
            }
            Self::IconCard => {
                "Leading icon in the tone's color; the detail shows as a second line."
            }
            Self::FilledAction => {
                "The primary action is an accent-filled button, the rest stay quiet."
            }
            Self::HoverClose => {
                "No close button until the pointer is on the toast: a calmer resting state."
            }
            Self::ProgressRing => {
                "A ring around the close button empties as the toast's time runs out."
            }
            Self::Trailing => {
                "Rests at the bottom trailing corner, out of the work's center; slides in from the edge."
            }
            Self::AccentTinted => {
                "A bar in the tone's color on the leading edge: errors read red at a glance."
            }
            Self::Solid => "Opaque theme surface, no glass: the most legible over a busy page.",
            Self::Flat => {
                "The window's background color, a 1 px edge, the button corner, no shadow."
            }
            Self::V2 => {
                "Quiet glass, a mark in the tone's color (a spinner while working), Undo as a small ink-filled button."
            }
        }
    }

    pub fn look(self) -> ToastLook {
        let mut look = ToastLook::default();
        match self {
            Self::Standard => {}
            Self::Capsule => {
                look.shape = ToastShape::Capsule;
                look.glass = Some(ToastGlass::Liquid);
                look.entrance = ToastEntrance::Pop;
            }
            Self::Compact => look.compact = true,
            Self::IconCard => {
                look.shows_icon = true;
                look.shows_detail_line = true;
            }
            Self::FilledAction => look.fills_action = true,
            Self::HoverClose => look.close_on_hover = true,
            Self::ProgressRing => look.shows_countdown = true,
            Self::Trailing => {
                look.placement = ToastPlacement::BottomTrailing;
                look.entrance = ToastEntrance::Slide;
            }
            Self::AccentTinted => look.accent_bar = true,
            Self::Solid => {
                look.solid = true;
                look.entrance = ToastEntrance::Pop;
            }
            Self::Flat => {
                look.solid = true;
                look.flat = true;
            }
            Self::V2 => {
                look.marks_tone = true;
                look.ink_action = true;
            }
        }
        look
    }

    pub fn info(self) -> ToastStyleInfo {
        ToastStyleInfo {
            raw_value: self.raw_value(),
            title: self.title(),
            summary: self.summary(),
            look: self.look(),
        }
    }
}

// MARK: Glass

/// CmuxToastGlass.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToastGlass {
    Liquid,
    LiquidVeil,
    Frost,
}

impl ToastGlass {
    pub const ALL: [ToastGlass; 3] = [Self::Liquid, Self::LiquidVeil, Self::Frost];

    pub fn title(self) -> &'static str {
        match self {
            Self::Liquid => "1: Liquid Glass, clear",
            Self::LiquidVeil => "3: Liquid Glass with the veil (readable)",
            Self::Frost => "11: Frosted blur with the veil",
        }
    }

    /// The glass gallery variant it draws.
    pub fn variant(self) -> &'static str {
        match self {
            Self::Liquid => "appKitRegular",
            Self::LiquidVeil => "veilTinted",
            Self::Frost => "frost",
        }
    }

    pub fn info(self) -> Value {
        json!({"rawValue": self, "title": self.title(), "variant": self.variant()})
    }
}

// MARK: Button row

/// CmuxToastButtonRow.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToastButtonRow {
    Plain,
    Divider,
    Chips,
}

/// How the row separates the buttons from the message.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ButtonRowSpacing {
    /// A divider goes after the text.
    pub divider: bool,
    /// Custom spacing after the text (divider only).
    pub after_text: Option<f64>,
    /// Custom spacing after the divider.
    pub after_divider: Option<f64>,
    /// The secondary and Don't Show Again buttons rest on a faint fill.
    pub rests_on_fill: bool,
}

impl ToastButtonRow {
    pub const ALL: [ToastButtonRow; 3] = [Self::Plain, Self::Divider, Self::Chips];
    /// CmuxToastDivider.height.
    pub const DIVIDER_HEIGHT: f64 = 14.0;

    pub fn title(self) -> &'static str {
        match self {
            Self::Plain => "Plain: buttons follow the message",
            Self::Divider => "Divider between message and buttons",
            Self::Chips => "Quiet buttons on a faint fill",
        }
    }

    pub fn info(self) -> Value {
        json!({"rawValue": self, "title": self.title()})
    }

    /// `separateButtons(in:after:)`: nothing when the toast has none of its buttons.
    pub fn spacing(
        self,
        has_secondary: bool,
        has_action: bool,
        has_never_show: bool,
    ) -> ButtonRowSpacing {
        let none = ButtonRowSpacing {
            divider: false,
            after_text: None,
            after_divider: None,
            rests_on_fill: false,
        };
        if !(has_secondary || has_action || has_never_show) {
            return none;
        }
        match self {
            Self::Plain => none,
            Self::Divider => {
                let gap = SPACE4;
                ButtonRowSpacing {
                    divider: true,
                    after_text: Some(gap),
                    after_divider: Some((gap - BUTTON_TITLE_PADDING).max(0.0)),
                    rests_on_fill: false,
                }
            }
            Self::Chips => ButtonRowSpacing { rests_on_fill: true, ..none },
        }
    }
}

/// Metrics.space2 and space4 (CmuxNextDesignTokens).
pub const SPACE2: f64 = 8.0;
pub const SPACE4: f64 = 16.0;
/// CmuxToastButton: height, title padding, chevron gap.
pub const BUTTON_HEIGHT: f64 = 22.0;
pub const BUTTON_TITLE_PADDING: f64 = 6.0;
pub const BUTTON_CHEVRON_GAP: f64 = 4.0;

// MARK: Toast

/// CmuxToast.Action.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToastAction {
    pub title: String,
    #[serde(default)]
    pub is_undo: bool,
    #[serde(default)]
    pub reveals_details: bool,
}

impl ToastAction {
    pub fn new(title: &str) -> Self {
        Self { title: title.into(), is_undo: false, reveals_details: false }
    }
    /// `.undo()`.
    pub fn undo() -> Self {
        Self { title: UNDO.into(), is_undo: true, reveals_details: false }
    }
    /// `.reopen()`.
    pub fn reopen() -> Self {
        Self::new(REOPEN)
    }
    /// `.details(title)`.
    pub fn details(title: &str) -> Self {
        Self { title: title.into(), is_undo: false, reveals_details: true }
    }
}

/// CmuxToast.refusalID.
pub const REFUSAL_ID: &str = "refusal";
/// CmuxToast.untilClosed: a duration of zero never ends on its own.
pub const UNTIL_CLOSED: f64 = 0.0;
/// The default duration, seconds.
pub const DEFAULT_SECONDS: f64 = 6.0;
/// `CmuxToastCenter.showNotice`'s duration.
pub const NOTICE_SECONDS: f64 = 3.0;

/// CmuxToast. Optional fields take the Swift init's defaults ([`Toast::normalized`]).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Toast {
    pub id: String,
    #[serde(default)]
    pub kind: Option<String>,
    pub message: String,
    #[serde(default)]
    pub detail: Option<String>,
    #[serde(default)]
    pub action: Option<ToastAction>,
    #[serde(default)]
    pub secondary_action: Option<ToastAction>,
    /// Seconds; 0 is untilClosed; absent is 6.
    #[serde(default)]
    pub duration: Option<f64>,
    #[serde(default)]
    pub tone: Option<ToastTone>,
    #[serde(default)]
    pub style: Option<ToastStyle>,
    #[serde(default)]
    pub one_window: bool,
    #[serde(default)]
    pub working: bool,
    #[serde(default)]
    pub keeps_duration: bool,
}

impl Toast {
    pub fn new(id: &str, message: &str) -> Self {
        Self {
            id: id.into(),
            kind: None,
            message: message.into(),
            detail: None,
            action: None,
            secondary_action: None,
            duration: None,
            tone: None,
            style: None,
            one_window: false,
            working: false,
            keeps_duration: false,
        }
    }

    /// The Swift init's defaults: tone error for a refusal else neutral, kind is the id, an empty
    /// detail is none, duration 6 s.
    pub fn normalized(mut self) -> Self {
        self.tone = Some(self.tone());
        self.kind = Some(self.kind().to_string());
        self.detail = self.detail.filter(|d| !d.is_empty());
        self.duration = Some(self.duration());
        self
    }

    pub fn tone(&self) -> ToastTone {
        self.tone.unwrap_or(if self.id == REFUSAL_ID {
            ToastTone::Error
        } else {
            ToastTone::Neutral
        })
    }

    pub fn kind(&self) -> &str {
        self.kind.as_deref().unwrap_or(&self.id)
    }

    pub fn duration(&self) -> f64 {
        self.duration.unwrap_or(DEFAULT_SECONDS)
    }

    pub fn detail(&self) -> Option<&str> {
        self.detail.as_deref().filter(|d| !d.is_empty())
    }

    pub fn is_undo(&self) -> bool {
        self.action.as_ref().is_some_and(|a| a.is_undo)
    }

    /// A toast that ends on its own, with no second choice and no action of its own beyond
    /// Details, offers Don't Show Again.
    pub fn offers_never_show(&self) -> bool {
        self.duration() != UNTIL_CLOSED
            && self.secondary_action.is_none()
            && self.action.as_ref().is_none_or(|a| a.reveals_details)
    }
}

// MARK: Stack

/// CmuxToastStack: a window's toasts, oldest first, at most [`ToastStack::LIMIT`].
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToastStack {
    #[serde(default)]
    pub serials: Vec<i64>,
    /// serial -> id, as pairs.
    #[serde(default)]
    pub ids: Vec<(i64, String)>,
    /// The undo toasts' serials.
    #[serde(default)]
    pub undo: Vec<i64>,
}

impl ToastStack {
    pub const LIMIT: usize = 3;

    fn id_of(&self, serial: i64) -> Option<&str> {
        self.ids.iter().find(|(s, _)| *s == serial).map(|(_, id)| id.as_str())
    }

    /// Pushes a toast; returns the serials it removed (same id first, then the oldest past the limit).
    pub fn push(&mut self, serial: i64, id: &str, undo: bool, keeps_slot: bool) -> Vec<i64> {
        let slot = if keeps_slot {
            self.serials.iter().position(|s| self.id_of(*s) == Some(id))
        } else {
            None
        };
        let mut removed: Vec<i64> =
            self.serials.iter().copied().filter(|s| self.id_of(*s) == Some(id)).collect();
        for old in removed.clone() {
            self.remove(old);
        }
        let at = slot.unwrap_or(self.serials.len()).min(self.serials.len());
        self.serials.insert(at, serial);
        self.ids.retain(|(s, _)| *s != serial);
        self.ids.push((serial, id.to_string()));
        if undo && !self.undo.contains(&serial) {
            self.undo.push(serial);
        }
        while self.serials.len() > Self::LIMIT {
            let oldest = self.serials[0];
            self.remove(oldest);
            removed.push(oldest);
        }
        removed
    }

    pub fn remove(&mut self, serial: i64) {
        self.serials.retain(|s| *s != serial);
        self.ids.retain(|(s, _)| *s != serial);
        self.undo.retain(|s| *s != serial);
    }

    /// The newest undo toast: Cmd-Z runs it.
    pub fn newest_undo(&self) -> Option<i64> {
        self.serials.iter().rev().copied().find(|s| self.undo.contains(s))
    }
}

// MARK: Tuning

/// CmuxToastTuning: the tunables' values.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToastTuning {
    pub duration_scale: f64,
    pub minimum_seconds: f64,
    pub glass: ToastGlass,
    pub padding: f64,
    pub button_spacing: f64,
    pub button_row: ToastButtonRow,
    pub message_width: f64,
    pub rise: f64,
}

impl Default for ToastTuning {
    fn default() -> Self {
        Self {
            duration_scale: 2.0,
            minimum_seconds: 6.0,
            glass: ToastGlass::LiquidVeil,
            padding: 8.0,
            button_spacing: 4.0,
            button_row: ToastButtonRow::Divider,
            message_width: 360.0,
            rise: 8.0,
        }
    }
}

impl ToastTuning {
    /// How long a toast shows: its time times the scale, at least the shortest time; a toast that
    /// never ends or keeps its exact time is as asked.
    pub fn shown_duration(&self, toast: &Toast) -> f64 {
        let d = toast.duration();
        if d == UNTIL_CLOSED || toast.keeps_duration {
            return d;
        }
        (d * self.duration_scale).max(self.minimum_seconds)
    }
}

/// CmuxToastTunables.section.
pub fn tunable_section() -> Value {
    json!({"id": "toasts", "title": "Toasts", "symbol": "text.bubble", "order": 13})
}

/// CmuxToastTunables.all, in order.
pub fn tunables() -> Vec<Value> {
    fn number(
        key: &str,
        title: &str,
        default: f64,
        range: (f64, f64),
        step: f64,
        unit: &str,
    ) -> Value {
        json!({"key": key, "title": title, "kind": "number", "default": default,
               "range": [range.0, range.1], "step": step, "unit": unit})
    }
    fn choice(key: &str, title: &str, default: &str) -> Value {
        json!({"key": key, "title": title, "kind": "choice", "default": default})
    }
    vec![
        number("toast.durationScale", "Duration scale", 2.0, (1.0, 5.0), 0.25, "multiplier"),
        number("toast.minimumSeconds", "Shortest time", 6.0, (1.0, 30.0), 0.5, "seconds"),
        choice("toast.glass", "Glass", "liquidVeil"),
        number("toast.verticalPadding", "Padding", 8.0, (2.0, 24.0), 1.0, "points"),
        number("toast.buttonSpacing", "Button spacing", 4.0, (0.0, 20.0), 1.0, "points"),
        choice("toast.buttonRow", "Buttons", "divider"),
        number("toast.messageWidth", "Message width", 360.0, (200.0, 640.0), 10.0, "points"),
        number("toast.rise", "Rise", 8.0, (0.0, 40.0), 1.0, "points"),
        choice("toast.playgroundFocus", "Playground shows", "all"),
    ]
}

// MARK: Strings

pub const UNDO: &str = "Undo";
pub const REOPEN: &str = "Reopen";
pub const UNDO_SHORTCUT: &str = "⌘Z";
pub const HIDE_DETAILS: &str = "Hide Details";
pub const DONT_SHOW_AGAIN: &str = "Don\u{2019}t Show Again";
pub const DISMISS: &str = "Dismiss";

/// CmuxToastStrings (English defaults).
pub fn strings() -> Value {
    json!({"undo": UNDO, "reopen": REOPEN, "undoShortcut": UNDO_SHORTCUT, "hideDetails": HIDE_DETAILS,
           "dontShowAgain": DONT_SHOW_AGAIN, "dismiss": DISMISS})
}

// MARK: Overlay geometry

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }
    pub fn min_x(&self) -> f64 {
        self.x
    }
    pub fn min_y(&self) -> f64 {
        self.y
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

/// CmuxToastOverlayHost: the toast sits this far above its floor.
pub const OVERLAY_LIFT: f64 = 24.0;
pub const STACK_GAP: f64 = 8.0;
pub const TRAILING_INSET: f64 = 16.0;

/// `CmuxToastOverlayHost.anchor(height:in:floor:below:)`.
pub fn overlay_anchor(height: f64, bounds: Rect, floor: Option<f64>, below: &[f64]) -> Rect {
    let base = bounds.min_y().max(floor.unwrap_or(bounds.min_y()) - OVERLAY_LIFT);
    let lift = below.iter().fold(0.0, |sum, h| sum + h + STACK_GAP);
    Rect::new(bounds.min_x(), base + lift, bounds.width, height)
}

/// `CmuxToastOverlayHost.trailing(_:width:in:)`.
pub fn overlay_trailing(anchor: Rect, width: f64, bounds: Rect) -> Rect {
    Rect::new(
        bounds.min_x().max(bounds.max_x() - TRAILING_INSET - width),
        anchor.min_y(),
        width,
        anchor.height,
    )
}

/// `CmuxToastOverlayHost.anchors(sizes:placements:in:floor:)`: each toast rests over the ones after
/// it (newer below); `floor(index, width)` is the avoidance floor for that toast's width.
pub fn overlay_anchors(
    sizes: &[Size],
    placements: &[ToastPlacement],
    bounds: Rect,
    floor: impl Fn(usize, f64) -> f64,
) -> Vec<Rect> {
    (0..sizes.len())
        .map(|index| {
            let below: Vec<f64> = sizes[index + 1..].iter().map(|s| s.height).collect();
            let anchor = overlay_anchor(
                sizes[index].height,
                bounds,
                Some(floor(index, sizes[index].width)),
                &below,
            );
            let placement = placements.get(index).copied().unwrap_or(ToastPlacement::BottomCenter);
            if placement == ToastPlacement::BottomTrailing {
                overlay_trailing(anchor, sizes[index].width, bounds)
            } else {
                anchor
            }
        })
        .collect()
}

// MARK: View numbers

pub const DETAIL_CAP: f64 = 240.0;
pub const EXPANDED_MESSAGE_LINES: i64 = 6;
pub const EXPANDED_MIN_WIDTH: f64 = 380.0;
pub const ACCENT_BAR_WIDTH: f64 = 4.0;
/// The capsule's controls are this tall.
pub const CAPSULE_CONTROL_HEIGHT: f64 = 22.0;

/// `CmuxToastView.detailCap(windowHeight:)`: the expanded detail's tallest, 40% of a short window.
pub fn detail_cap(window_height: Option<f64>) -> f64 {
    match window_height {
        Some(h) if h > 0.0 => DETAIL_CAP.min((h * 0.4).floor()),
        _ => DETAIL_CAP,
    }
}

/// The look's padding: two thirds, rounded, when compact.
pub fn look_padding(padding: f64, compact: bool) -> f64 {
    if compact { (padding * 2.0 / 3.0).round() } else { padding }
}

/// Every fixed number the toast view and its motion use.
pub fn metrics() -> Value {
    json!({
        "detailCap": DETAIL_CAP, "expandedMessageLines": EXPANDED_MESSAGE_LINES,
        "expandedMinWidth": EXPANDED_MIN_WIDTH, "accentBarWidth": ACCENT_BAR_WIDTH,
        "capsuleControlHeight": CAPSULE_CONTROL_HEIGHT,
        "buttonHeight": BUTTON_HEIGHT, "buttonTitlePadding": BUTTON_TITLE_PADDING,
        "buttonChevronGap": BUTTON_CHEVRON_GAP, "dividerHeight": ToastButtonRow::DIVIDER_HEIGHT,
        "overlayLift": OVERLAY_LIFT, "stackGap": STACK_GAP, "trailingInset": TRAILING_INSET,
        "popScale": POP_SCALE, "slideDistance": SLIDE_DISTANCE,
        "closedCooldown": crate::toast::center::CLOSED_COOLDOWN_SECONDS, "stackLimit": ToastStack::LIMIT,
        "defaultSeconds": DEFAULT_SECONDS, "noticeSeconds": NOTICE_SECONDS,
    })
}

// MARK: Motion

/// CmuxToastMotion: a pop grows from 95%, a slide comes 32 pt from the edge.
pub const POP_SCALE: f64 = 0.95;
pub const SLIDE_DISTANCE: f64 = 32.0;

/// How a toast leaves, by its entrance.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExitMotion {
    pub scale: Option<f64>,
    pub slide: Option<f64>,
}

pub fn exit_motion(entrance: ToastEntrance) -> ExitMotion {
    match entrance {
        ToastEntrance::Pop => ExitMotion { scale: Some(0.97), slide: None },
        ToastEntrance::Slide => ExitMotion { scale: None, slide: Some(16.0) },
        ToastEntrance::Rise => ExitMotion { scale: None, slide: None },
    }
}

// MARK: Playground

/// CmuxToastPlaygroundFocus: every style, or one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlaygroundFocus {
    All,
    Style(ToastStyle),
}

impl PlaygroundFocus {
    pub fn all_cases() -> Vec<PlaygroundFocus> {
        std::iter::once(Self::All).chain(ToastStyle::ALL.into_iter().map(Self::Style)).collect()
    }
    pub fn from_raw(raw: &str) -> Option<Self> {
        if raw == "all" { Some(Self::All) } else { ToastStyle::from_raw(raw).map(Self::Style) }
    }
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::Style(s) => s.raw_value(),
        }
    }
    pub fn title(self) -> &'static str {
        match self {
            Self::All => "All styles",
            Self::Style(s) => s.title(),
        }
    }
    pub fn styles(self) -> Vec<ToastStyle> {
        match self {
            Self::All => ToastStyle::ALL.to_vec(),
            Self::Style(s) => vec![s],
        }
    }
}

/// The playground's light and dark themes.
pub const PLAYGROUND_LIGHT_THEME: &str = "Soft Blue Light";
pub const PLAYGROUND_DARK_THEME: &str = "Soft Blue";

/// CmuxToastPlaygroundSamples.kinds.
pub fn playground_kinds() -> Vec<Toast> {
    let mut notice =
        Toast::new("playground.notice", "Copied the link to \u{201c}Release notes\u{201d}");
    notice.detail = Some("https://cmux.com/changelog".into());
    notice.tone = Some(ToastTone::Success);
    let mut undo = Toast::new("playground.undo", "Closed \u{201c}zsh\u{201d}");
    undo.action = Some(ToastAction::undo());
    let mut details = Toast::new(
        "playground.details",
        "Couldn\u{2019}t save \u{201c}notes.md\u{201d}: the disk is full",
    );
    details.detail = Some("fs.no_space: write(2) returned ENOSPC".into());
    details.action = Some(ToastAction::details("Details"));
    details.tone = Some(ToastTone::Warning);
    let mut error = Toast::new("playground.error", "No room for another split");
    error.tone = Some(ToastTone::Error);
    let mut prompt = Toast::new("playground.prompt", "A server update is ready");
    prompt.detail = Some("cmux-tui 0.214 restarts your sessions in place".into());
    prompt.action = Some(ToastAction::new("Restart"));
    prompt.secondary_action = Some(ToastAction::new("Later"));
    prompt.duration = Some(UNTIL_CLOSED);
    [
        Toast::new("playground.hint", "Option or Shift + drag selects text"),
        notice,
        undo,
        details,
        error,
        prompt,
    ]
    .into_iter()
    .map(Toast::normalized)
    .collect()
}

/// CmuxToastPlaygroundSamples.sidebarRefusals.
pub fn playground_sidebar_refusals() -> Vec<Toast> {
    let mut detail =
        Toast::new("playground.sidebarRefusal.detail", "\u{201c}Work\u{201d} went back");
    detail.detail = Some("A group can\u{2019}t go inside itself or nest more than 16 deep.".into());
    detail.tone = Some(ToastTone::Warning);
    [
        Toast::new(
            "playground.sidebarRefusal.reason",
            "A group can\u{2019}t go inside itself or nest more than 16 deep.",
        ),
        Toast::new(
            "playground.sidebarRefusal.verb",
            "Can\u{2019}t move \u{201c}Work\u{201d}: a group can\u{2019}t go inside itself or nest more than 16 deep.",
        ),
        detail,
    ]
    .into_iter()
    .map(Toast::normalized)
    .collect()
}

/// kinds then refusals.
pub fn playground_sheet() -> Vec<Toast> {
    let mut sheet = playground_kinds();
    sheet.extend(playground_sidebar_refusals());
    sheet
}

/// The ones the playground's Fire button shows.
pub fn playground_fired() -> Vec<Toast> {
    let kinds = playground_kinds();
    vec![kinds[0].clone(), kinds[2].clone(), kinds[5].clone()]
}

// MARK: Surface zoom

/// SurfaceZoomIndicator's toast: the percent for 1 s, its exact time.
pub fn surface_zoom_toast(percent: i64) -> Toast {
    let mut toast = Toast::new("surface-zoom", &format!("{percent}%"));
    toast.duration = Some(1.0);
    toast.keeps_duration = true;
    toast.normalized()
}
