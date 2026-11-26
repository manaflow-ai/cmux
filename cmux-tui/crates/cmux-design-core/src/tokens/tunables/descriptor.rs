//! The tunable's value types and the descriptor's pure rules: ports `TunableReadCadence` and
//! `TunableDescriptor` (CmuxNextDesignTokens/Tunables/TunableDescriptor.swift) with the types it
//! holds (`TunableValue`, `TunableUnit`, `TunableKind` and its `clamp`, `TunableChoiceOption`,
//! `TunableSection`), plus the number rules Debug Settings applies to a descriptor: the step snap
//! and percent display (`DebugTunableControls`), `TunableExport.format` and the value text
//! (`DebugSettingsStrings.formatted`, with the English defaults of its localized unit strings).

use serde::{Deserialize, Serialize};

/// Swift's `max(a, b)`: `b >= a ? b : a`.
pub(crate) fn smax(a: f64, b: f64) -> f64 {
    if b >= a { b } else { a }
}

/// Swift's `min(a, b)`: `b < a ? b : a`.
pub(crate) fn smin(a: f64, b: f64) -> f64 {
    if b < a { b } else { a }
}

/// `min(max(value, lo), hi)`, in Swift's order.
pub(crate) fn clamp_to(value: f64, lo: f64, hi: f64) -> f64 {
    smin(smax(value, lo), hi)
}

/// `TunableReadCadence`: when the app reads a tunable.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TunableReadCadence {
    /// Read where it is used, so a change applies at once.
    #[default]
    Live,
    /// Read once at process start; a change needs a relaunch.
    Launch,
}

impl TunableReadCadence {
    /// `allCases`, in order.
    pub const ALL: [TunableReadCadence; 2] = [TunableReadCadence::Live, TunableReadCadence::Launch];

    /// `rawValue`.
    pub fn raw(self) -> &'static str {
        match self {
            TunableReadCadence::Live => "live",
            TunableReadCadence::Launch => "launch",
        }
    }

    /// `TunableReadCadence(rawValue:)`.
    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|c| c.raw() == raw)
    }
}

/// `SpringParameters`: a spring's response (seconds) and damping fraction.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpringParameters {
    /// Response, seconds.
    pub response: f64,
    /// Damping fraction.
    pub damping_fraction: f64,
}

/// `TunableValue`: one stored tunable value (`{"number": 1}`, `{"choice": "none"}`, ...). A colour
/// is its `TunableColor` raw value.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TunableValue {
    /// A number.
    Number(f64),
    /// A flag.
    Bool(bool),
    /// A choice's raw value.
    Choice(String),
    /// A `TunableColor` raw value.
    Color(String),
    /// A spring.
    Spring(SpringParameters),
}

impl TunableValue {
    /// `number`.
    pub fn number(&self) -> Option<f64> {
        if let TunableValue::Number(n) = self { Some(*n) } else { None }
    }
    /// `bool`.
    pub fn bool(&self) -> Option<bool> {
        if let TunableValue::Bool(b) = self { Some(*b) } else { None }
    }
    /// `choice`.
    pub fn choice(&self) -> Option<&str> {
        if let TunableValue::Choice(c) = self { Some(c) } else { None }
    }
    /// `color`.
    pub fn color(&self) -> Option<&str> {
        if let TunableValue::Color(c) = self { Some(c) } else { None }
    }
    /// `spring`.
    pub fn spring(&self) -> Option<SpringParameters> {
        if let TunableValue::Spring(s) = self { Some(*s) } else { None }
    }
}

/// `TunableUnit`: what a number means.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TunableUnit {
    /// Points.
    Points,
    /// Seconds.
    Seconds,
    /// 0...1, shown as a percentage.
    Fraction,
    /// A plain factor.
    Multiplier,
    /// Points per second.
    PointsPerSecond,
    /// A count.
    Count,
}

impl TunableUnit {
    /// `allCases`, in order.
    pub const ALL: [TunableUnit; 6] = [
        TunableUnit::Points,
        TunableUnit::Seconds,
        TunableUnit::Fraction,
        TunableUnit::Multiplier,
        TunableUnit::PointsPerSecond,
        TunableUnit::Count,
    ];

    /// The number control's suffix (`DebugTunableControls.unitSuffix`).
    pub fn suffix(self) -> &'static str {
        match self {
            TunableUnit::Points => "pt",
            TunableUnit::Seconds => "s",
            TunableUnit::Fraction => "%",
            TunableUnit::Multiplier => "×",
            TunableUnit::PointsPerSecond => "pt/s",
            TunableUnit::Count => "",
        }
    }
}

/// `TunableChoiceOption`: one option of a choice tunable.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TunableChoiceOption {
    /// The raw value.
    pub value: String,
    /// The Debug Settings title.
    pub title: String,
}

impl TunableChoiceOption {
    /// An option.
    pub fn new(value: impl Into<String>, title: impl Into<String>) -> Self {
        TunableChoiceOption { value: value.into(), title: title.into() }
    }
}

/// `TunableKind.number`'s payload.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NumberKind {
    /// The closed range, `[lower, upper]`.
    pub range: (f64, f64),
    /// The slider step.
    pub step: f64,
    /// The unit.
    pub unit: TunableUnit,
}

/// `TunableKind`: the control a tunable gets, and how its values are clamped.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TunableKind {
    /// A number in a range.
    Number(NumberKind),
    /// A flag.
    Bool,
    /// One of the options.
    Choice(Vec<TunableChoiceOption>),
    /// A theme colour.
    Color,
    /// Response and damping.
    Spring,
}

/// `TunableKind.springResponseRange`.
pub const SPRING_RESPONSE_RANGE: (f64, f64) = (0.02, 2.0);
/// `TunableKind.springDampingRange`.
pub const SPRING_DAMPING_RANGE: (f64, f64) = (1.0, 1.5);

impl TunableKind {
    /// `.number(range:step:unit:)`.
    pub fn number(range: (f64, f64), step: f64, unit: TunableUnit) -> Self {
        TunableKind::Number(NumberKind { range, step, unit })
    }

    /// `clamp(_:)`: `value` made valid for this kind, or None when it has the wrong type, is not
    /// finite or names no option.
    pub fn clamp(&self, value: &TunableValue) -> Option<TunableValue> {
        match (self, value) {
            (TunableKind::Number(kind), TunableValue::Number(number)) => {
                if !number.is_finite() {
                    return None;
                }
                Some(TunableValue::Number(clamp_to(*number, kind.range.0, kind.range.1)))
            }
            (TunableKind::Bool, TunableValue::Bool(_))
            | (TunableKind::Color, TunableValue::Color(_)) => Some(value.clone()),
            (TunableKind::Choice(options), TunableValue::Choice(raw)) => {
                options.iter().any(|o| &o.value == raw).then(|| value.clone())
            }
            (TunableKind::Spring, TunableValue::Spring(spring)) => {
                if !spring.response.is_finite() || !spring.damping_fraction.is_finite() {
                    return None;
                }
                let response =
                    clamp_to(spring.response, SPRING_RESPONSE_RANGE.0, SPRING_RESPONSE_RANGE.1);
                let damping = clamp_to(
                    spring.damping_fraction,
                    SPRING_DAMPING_RANGE.0,
                    SPRING_DAMPING_RANGE.1,
                );
                Some(TunableValue::Spring(SpringParameters { response, damping_fraction: damping }))
            }
            _ => None,
        }
    }
}

/// `TunableSection`: a Debug Settings sidebar section.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TunableSection {
    /// The id.
    pub id: String,
    /// The title.
    pub title: String,
    /// SF Symbol name.
    pub symbol: String,
    /// Sidebar order.
    pub order: i64,
}

impl TunableSection {
    /// A section.
    pub fn new(id: &str, title: &str, symbol: &str, order: i64) -> Self {
        TunableSection { id: id.into(), title: title.into(), symbol: symbol.into(), order }
    }
}

/// `TunableDescriptor.DefaultSource`: a constant, or a value code derives (evaluated here).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DefaultSource {
    /// A constant default.
    Fixed(TunableValue),
    /// A derived default, as code computes it for the descriptor's own inputs.
    Derived(TunableValue),
}

/// `TunableDescriptor`: everything Debug Settings and the exports know about one tunable.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TunableDescriptor {
    /// The stable dotted key (`id`).
    pub key: String,
    /// The section.
    pub section: TunableSection,
    /// The label.
    pub label: String,
    /// The help line.
    pub help: String,
    /// The kind.
    pub kind: TunableKind,
    /// Where the default comes from.
    pub default_source: DefaultSource,
    /// The Swift name that holds the default; None uses the key.
    pub code_name: Option<String>,
    /// When the app reads it (`live` unless declared otherwise).
    #[serde(default)]
    pub read_cadence: TunableReadCadence,
}

impl TunableDescriptor {
    /// `id`: the key.
    pub fn id(&self) -> &str {
        &self.key
    }

    /// `defaultValue`.
    pub fn default_value(&self) -> &TunableValue {
        match &self.default_source {
            DefaultSource::Fixed(v) | DefaultSource::Derived(v) => v,
        }
    }

    /// `clamp(_:)`: the kind's clamp.
    pub fn clamp(&self, value: &TunableValue) -> Option<TunableValue> {
        self.kind.clamp(value)
    }
}

/// `TunableExport.format`: a number to 4 decimals, trailing zeros dropped, whole numbers bare.
pub fn format_number(number: f64) -> String {
    let rounded = (number * 10_000.0).round() / 10_000.0;
    if rounded == rounded.round() && rounded.abs() < 1e12 {
        return format!("{}", rounded as i64);
    }
    let mut text = format!("{rounded:.4}");
    while text.ends_with('0') {
        text.pop();
    }
    text
}

/// `DebugTunableControls.display`: a fraction as a percentage to one decimal, else as stored.
pub fn display_number(number: f64, unit: TunableUnit) -> f64 {
    if unit == TunableUnit::Fraction { (number * 1000.0).round() / 10.0 } else { number }
}

/// `DebugTunableControls.snap`: `number` on the step grid from the range's lower bound, to 4
/// decimals; unchanged when the step is not positive.
pub fn snap(number: f64, range: (f64, f64), step: f64) -> f64 {
    if step <= 0.0 {
        return number;
    }
    let steps = ((number - range.0) / step).round();
    ((range.0 + steps * step) * 10_000.0).round() / 10_000.0
}

/// `DebugSettingsStrings.formatted(_:unit:)` with the English unit strings (`%@ pt`, `%@ s`).
pub fn format_with_unit(number: f64, unit: TunableUnit) -> String {
    let text = format_number(number);
    match unit {
        TunableUnit::Points => format!("{text} pt"),
        TunableUnit::Seconds => format!("{text} s"),
        TunableUnit::Fraction => format!("{}%", format_number((number * 1000.0).round() / 10.0)),
        TunableUnit::Multiplier => format!("{text}×"),
        TunableUnit::PointsPerSecond => format!("{text} pt/s"),
        TunableUnit::Count => text,
    }
}

/// `DebugSettingsStrings`' value text for `value` of `kind` (`on`/`off` are the flag's words).
pub fn format_value(value: &TunableValue, kind: &TunableKind, on: &str, off: &str) -> String {
    match value {
        TunableValue::Number(number) => match kind {
            TunableKind::Number(k) => format_with_unit(*number, k.unit),
            _ => format_number(*number),
        },
        TunableValue::Bool(flag) => (if *flag { on } else { off }).to_string(),
        TunableValue::Choice(raw) => {
            if let TunableKind::Choice(options) = kind
                && let Some(option) = options.iter().find(|o| &o.value == raw)
            {
                return option.title.clone();
            }
            raw.clone()
        }
        TunableValue::Color(color) => color.clone(),
        TunableValue::Spring(spring) => {
            format!(
                "{} s / {}",
                format_number(spring.response),
                format_number(spring.damping_fraction)
            )
        }
    }
}
