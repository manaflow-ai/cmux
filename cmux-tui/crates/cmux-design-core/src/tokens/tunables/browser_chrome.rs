//! The browser pane's tab bar and omnibar numbers per density: ports `BrowserChromeMetric`
//! (CmuxNextDesign/Tunables/BrowserChromeMetric.swift) and the pure rules of
//! `BrowserChromeTuning` (BrowserChromeTuning.swift): `section`, `densities`, `key`, `all` and
//! `descriptors`, `override(_:tokens:store:)` over a key-to-value map, `defaultValue(_:tokens:row:)`,
//! `chipLeading`, `textOrigin`, `share` and `half`. The density comes in as the density module's
//! [`DensityTokens`] (its port of the Swift type).

use super::descriptor::{
    DefaultSource, TunableDescriptor, TunableKind, TunableSection, TunableUnit, TunableValue, smax,
    smin,
};
use crate::tokens::density::tokens::reference_tokens;
use crate::tokens::density::{DensityPreset, DensityTokens};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// `BrowserChromeMetric`: one tuned number of the browser chrome.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BrowserChromeMetric {
    /// Tab pill and omnibar height.
    RowHeight,
    /// The gap above, between and under the rows.
    RowGap,
    /// The tab x's hover square.
    CloseSize,
    /// The hover square's corner.
    CloseCorner,
    /// The x's ink.
    CloseInk,
    /// The hover square to the pill's trailing edge.
    CloseTrailing,
    /// The hover fill, percent of the tab's ink.
    CloseHoverOpacity,
    /// The page-info chip's inset.
    ChipLeading,
    /// Where the URL's text starts.
    TextOrigin,
}

impl BrowserChromeMetric {
    /// `allCases`, in order.
    pub const ALL: [BrowserChromeMetric; 9] = [
        BrowserChromeMetric::RowHeight,
        BrowserChromeMetric::RowGap,
        BrowserChromeMetric::CloseSize,
        BrowserChromeMetric::CloseCorner,
        BrowserChromeMetric::CloseInk,
        BrowserChromeMetric::CloseTrailing,
        BrowserChromeMetric::CloseHoverOpacity,
        BrowserChromeMetric::ChipLeading,
        BrowserChromeMetric::TextOrigin,
    ];

    /// `rawValue`.
    pub fn raw(self) -> &'static str {
        match self {
            BrowserChromeMetric::RowHeight => "rowHeight",
            BrowserChromeMetric::RowGap => "rowGap",
            BrowserChromeMetric::CloseSize => "closeSize",
            BrowserChromeMetric::CloseCorner => "closeCorner",
            BrowserChromeMetric::CloseInk => "closeInk",
            BrowserChromeMetric::CloseTrailing => "closeTrailing",
            BrowserChromeMetric::CloseHoverOpacity => "closeHoverOpacity",
            BrowserChromeMetric::ChipLeading => "chipLeading",
            BrowserChromeMetric::TextOrigin => "textOrigin",
        }
    }

    /// `BrowserChromeMetric(rawValue:)`.
    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|m| m.raw() == raw)
    }

    /// `token`: the density token that holds the row and the gap.
    pub fn token(self) -> Option<&'static str> {
        match self {
            BrowserChromeMetric::RowHeight => Some("browserRowHeight"),
            BrowserChromeMetric::RowGap => Some("browserRowGap"),
            _ => None,
        }
    }

    /// `densityKey`: the density token a custom density sets this with.
    pub fn density_key(self) -> Option<&'static str> {
        match self {
            BrowserChromeMetric::CloseSize => Some("tabCloseSize"),
            BrowserChromeMetric::CloseInk => Some("tabCloseGlyphSize"),
            BrowserChromeMetric::CloseCorner => Some("tabCloseCornerRadius"),
            BrowserChromeMetric::CloseTrailing => Some("tabTrailingInset"),
            _ => None,
        }
    }

    /// `label`: the Debug Settings label.
    pub fn label(self) -> &'static str {
        match self {
            BrowserChromeMetric::RowHeight => "Row height",
            BrowserChromeMetric::RowGap => "Row gap",
            BrowserChromeMetric::CloseSize => "Close square",
            BrowserChromeMetric::CloseCorner => "Close corner",
            BrowserChromeMetric::CloseInk => "Close ink",
            BrowserChromeMetric::CloseTrailing => "Close to tab end",
            BrowserChromeMetric::CloseHoverOpacity => "Close hover fill %",
            BrowserChromeMetric::ChipLeading => "Omnibar chip inset",
            BrowserChromeMetric::TextOrigin => "Omnibar text start",
        }
    }

    /// `help`: the Debug Settings help line.
    pub fn help(self) -> &'static str {
        match self {
            BrowserChromeMetric::RowHeight => "Tab pill and omnibar height. Helium: 28.",
            BrowserChromeMetric::RowGap => {
                "Gap above the tabs, between tabs and omnibar, and under the omnibar. Helium: 3."
            }
            BrowserChromeMetric::CloseSize => {
                "Side of the tab x's hover square. Helium: 14 on a 28 pt tab."
            }
            BrowserChromeMetric::CloseCorner => "Corner of the x's hover square. Helium: 4.",
            BrowserChromeMetric::CloseInk => "Side of the x's ink. Helium: 8.",
            BrowserChromeMetric::CloseTrailing => {
                "Hover square to the pill's trailing edge. Helium: 6."
            }
            BrowserChromeMetric::CloseHoverOpacity => {
                "Hover fill, percent of the tab's ink; pressed is 2 less, no fade. Helium: 16."
            }
            BrowserChromeMetric::ChipLeading => "Bar edge to the page-info chip. Helium: 2.",
            BrowserChromeMetric::TextOrigin => "Bar edge to the URL's text. Helium: 31.",
        }
    }

    /// `range`: the slider's range (percent for the hover opacity).
    pub fn range(self) -> (f64, f64) {
        match self {
            BrowserChromeMetric::RowHeight => (16.0, 48.0),
            BrowserChromeMetric::RowGap => (0.0, 12.0),
            BrowserChromeMetric::CloseSize | BrowserChromeMetric::CloseInk => (4.0, 28.0),
            BrowserChromeMetric::CloseCorner
            | BrowserChromeMetric::CloseTrailing
            | BrowserChromeMetric::ChipLeading => (0.0, 16.0),
            BrowserChromeMetric::TextOrigin => (10.0, 60.0),
            BrowserChromeMetric::CloseHoverOpacity => (0.0, 40.0),
        }
    }
}

/// `BrowserChromeTuning.section`.
pub fn section() -> TunableSection {
    TunableSection::new("browserChrome", "Browser Chrome", "macwindow", 14)
}

/// `BrowserChromeTuning.densities`: the densities with their own values, smallest first.
pub const DENSITIES: [DensityPreset; 4] = [
    DensityPreset::Compact,
    DensityPreset::Cozy,
    DensityPreset::Comfortable,
    DensityPreset::Spacious,
];

/// `BrowserChromeTuning.key(_:density:)`: `browserChrome.<density>.<metric>`.
pub fn key(metric: BrowserChromeMetric, density: DensityPreset) -> String {
    format!("browserChrome.{}.{}", density.raw(), metric.raw())
}

/// `BrowserChromeTuning.half`: the nearest half point.
pub fn half(value: f64) -> f64 {
    (value * 2.0).round() / 2.0
}

/// `BrowserChromeTuning.share(_:of:)`: `points` of Helium's 28 pt row as the same share of `row`.
pub fn share(points: f64, row: f64) -> f64 {
    half(row * points / 28.0)
}

/// `BrowserChromeTuning.chipLeading(bar:chromeColumn:)`.
pub fn chip_leading(bar: f64, chrome_column: bool) -> f64 {
    if !chrome_column {
        return smax(2.0, half(bar * 2.0 / 28.0));
    }
    smax(2.0, (bar * 22.0 / 30.0 - (bar - 4.0) / 2.0).round())
}

/// `BrowserChromeTuning.textOrigin(bar:chromeColumn:)`.
pub fn text_origin(bar: f64, chrome_column: bool) -> f64 {
    if !chrome_column {
        return half(bar * 31.0 / 28.0);
    }
    let chip = chip_leading(bar, true);
    chip + (bar - 4.0) + smax(5.0, (bar * 42.0 / 30.0 - chip - (bar - 4.0)).round()) + 3.0
}

/// `BrowserChromeTuning.defaultValue(_:tokens:row:)`: Helium's share of `row` (the density's
/// `browserRowHeight` when None), or the density's own token.
pub fn default_value(metric: BrowserChromeMetric, tokens: &DensityTokens, row: Option<f64>) -> f64 {
    let t = |k: &str| tokens.token(k);
    let row = row.or_else(|| t("browserRowHeight")).unwrap_or(28.0);
    let chrome_column = t("omnibarChromeColumn").unwrap_or(0.0) > 0.0;
    let uniform = tokens.uniform_scale();
    let factor = uniform.unwrap_or(1.0);
    let size_row = if uniform.is_none() {
        row
    } else {
        reference_tokens().token("browserRowHeight").unwrap_or(28.0)
    };
    if let Some(exact) = metric.density_key().and_then(t) {
        return exact;
    }
    match metric {
        BrowserChromeMetric::RowHeight | BrowserChromeMetric::RowGap => {
            metric.token().and_then(t).unwrap_or(0.0)
        }
        BrowserChromeMetric::CloseSize => half(share(14.0, size_row) * factor),
        BrowserChromeMetric::CloseCorner => half(half(share(14.0, size_row) * 4.0 / 14.0) * factor),
        BrowserChromeMetric::CloseInk => half(share(8.0, size_row) * factor),
        BrowserChromeMetric::CloseTrailing => half(share(6.0, size_row) * factor),
        BrowserChromeMetric::CloseHoverOpacity => 16.0,
        BrowserChromeMetric::ChipLeading => {
            if let Some(leading) = t("omnibarIconLeading") {
                return leading;
            }
            chip_leading(t("omnibarHeight").unwrap_or(row), chrome_column)
        }
        BrowserChromeMetric::TextOrigin => {
            if let (Some(leading), Some(view), Some(gap)) =
                (t("omnibarIconLeading"), t("omnibarIconViewSize"), t("omnibarTextGap"))
            {
                let bar = t("omnibarHeight").unwrap_or(row);
                let edge = t("omnibarEdgeInset").unwrap_or(2.0);
                return leading + smin(view, bar - 2.0 * edge) + gap;
            }
            text_origin(t("omnibarHeight").unwrap_or(row), chrome_column)
        }
    }
}

/// `usesChromeColumn` for `tokens`: the `omnibarChromeColumn` token is above 0.
pub fn uses_chrome_column(tokens: &DensityTokens) -> bool {
    tokens.token("omnibarChromeColumn").unwrap_or(0.0) > 0.0
}

/// The tunable density `tokens` draws, if any: a built-in in [`DENSITIES`].
pub fn tunable_density(tokens_id: &str) -> Option<DensityPreset> {
    DensityPreset::from_raw(tokens_id).filter(|d| DENSITIES.contains(d))
}

/// `BrowserChromeTuning.override(_:tokens:store:)` over `overrides` (key to stored value): the
/// number stored for `metric` at the density `tokens_id` names, if it is a tunable one.
pub fn override_value(
    metric: BrowserChromeMetric,
    tokens_id: &str,
    overrides: &BTreeMap<String, TunableValue>,
) -> Option<f64> {
    let density = tunable_density(tokens_id)?;
    overrides.get(&key(metric, density)).and_then(TunableValue::number)
}

/// `BrowserChromeTuning.value`: the override, else `default`.
pub fn value(
    metric: BrowserChromeMetric,
    tokens: &DensityTokens,
    row: Option<f64>,
    overrides: &BTreeMap<String, TunableValue>,
) -> f64 {
    override_value(metric, &tokens.id, overrides)
        .unwrap_or_else(|| default_value(metric, tokens, row))
}

/// `BrowserChromeTuning.descriptors`: every metric of every density, by density then metric
/// (`ComputedTunable`: 0.5 pt steps in points), each derived default at its density.
pub fn descriptors() -> Vec<TunableDescriptor> {
    let section = section();
    DENSITIES
        .iter()
        .flat_map(|&density| {
            let section = section.clone();
            BrowserChromeMetric::ALL.into_iter().map(move |metric| {
                let tokens = density.tokens();
                TunableDescriptor {
                    key: key(metric, density),
                    section: section.clone(),
                    label: format!("{}: {}", tokens.name, metric.label()),
                    help: metric.help().into(),
                    kind: TunableKind::number(metric.range(), 0.5, TunableUnit::Points),
                    default_source: DefaultSource::Derived(TunableValue::Number(default_value(
                        metric, tokens, None,
                    ))),
                    code_name: Some(format!("BrowserChromeTuning.{}", metric.raw())),
                    read_cadence: Default::default(),
                }
            })
        })
        .collect()
}
