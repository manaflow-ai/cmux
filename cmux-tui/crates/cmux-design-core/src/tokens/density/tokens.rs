//! A local port of `DensityTokens` and `DensityPreset` (CmuxNextDesign/DensityTokens.swift and
//! DensityPreset.swift): the parts the catalog, the page scales and the card scale read.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::OnceLock;

/// Swift's `max(a, b)`: `b >= a ? b : a`.
pub(crate) fn smax(a: f64, b: f64) -> f64 {
    if b >= a { b } else { a }
}

/// Swift's `min(a, b)`: `b < a ? b : a`.
pub(crate) fn smin(a: f64, b: f64) -> f64 {
    if b < a { b } else { a }
}

/// Swift's `clamped(to: lo...hi)`: `min(max(v, lo), hi)`.
pub(crate) fn clamp(v: f64, lo: f64, hi: f64) -> f64 {
    smin(smax(v, lo), hi)
}

/// `DensityTokens.half`: the nearest half point.
pub fn half(value: f64) -> f64 {
    (value * 2.0).round() / 2.0
}

/// `DensityTokens.levelRange`.
pub const LEVEL_RANGE: (f64, f64) = (-1.0, 2.5);
/// `DensityTokens.spacingRange`.
pub const SPACING_RANGE: (f64, f64) = (0.5, 2.0);
/// `DensityTokens.fontSizeRange`.
pub const FONT_SIZE_RANGE: (f64, f64) = (9.0, 20.0);

/// `Density`: a density's family.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Family {
    /// Under level 0.5.
    Compact,
    /// Level 0.5 and up.
    Comfortable,
}

/// `DensityTokens`: a density on the wire (`basedOn`, `fontSize` optional; `level` 0 and
/// `spacing` 1 by default). Build one with [`DensityTokens::new`] to apply Swift's init clamps.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DensityTokens {
    /// The id (a preset's raw value for built-ins).
    pub id: String,
    /// The shown name.
    pub name: String,
    /// The preset a custom density starts from.
    #[serde(default)]
    pub based_on: Option<String>,
    /// The compact-to-comfortable level.
    #[serde(default)]
    pub level: f64,
    /// The spacing factor.
    #[serde(default = "one")]
    pub spacing: f64,
    /// The chrome body size, when set.
    #[serde(default)]
    pub font_size: Option<f64>,
    /// Exact token values by key.
    #[serde(default)]
    pub tokens: BTreeMap<String, f64>,
}

fn one() -> f64 {
    1.0
}

impl DensityTokens {
    /// `DensityTokens.init`: clamps level, spacing and font size; keeps finite, non-negative tokens.
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        based_on: Option<String>,
        level: f64,
        spacing: f64,
        font_size: Option<f64>,
        tokens: BTreeMap<String, f64>,
    ) -> Self {
        DensityTokens {
            id: id.into(),
            name: name.into(),
            based_on,
            level: clamp(level, LEVEL_RANGE.0, LEVEL_RANGE.1),
            spacing: clamp(spacing, SPACING_RANGE.0, SPACING_RANGE.1),
            font_size: font_size.map(|f| clamp(f, FONT_SIZE_RANGE.0, FONT_SIZE_RANGE.1)),
            tokens: tokens.into_iter().filter(|(_, v)| v.is_finite() && *v >= 0.0).collect(),
        }
    }

    /// The token `key`'s exact value.
    pub fn token(&self, key: &str) -> Option<f64> {
        self.tokens.get(key).copied()
    }

    /// `family`: compact under level 0.5.
    pub fn family(&self) -> Family {
        if self.level < 0.5 { Family::Compact } else { Family::Comfortable }
    }

    /// `isBuiltIn`: the id names a preset.
    pub fn is_built_in(&self) -> bool {
        DensityPreset::from_raw(&self.id).is_some()
    }

    /// `uniformScale`: the `densityScale` token.
    pub fn uniform_scale(&self) -> Option<f64> {
        self.token("densityScale")
    }

    /// `usesDefaultRowFill`: a uniform scale, or Default itself.
    pub fn uses_default_row_fill(&self) -> bool {
        self.uniform_scale().is_some() || self.id == DensityPreset::Cozy.raw()
    }

    /// `resolve(compact:comfortable:token:)`.
    pub fn resolve(&self, compact: f64, comfortable: f64, token: Option<&str>) -> f64 {
        if let Some(exact) = token.and_then(|t| self.token(t)) {
            return exact;
        }
        if let Some(u) = self.uniform_scale() {
            return half(reference_tokens().resolve(compact, comfortable, None) * u);
        }
        if self.level == 0.0 {
            return compact;
        }
        if self.level == 1.0 {
            return comfortable;
        }
        (compact + (comfortable - compact) * self.level).round()
    }

    /// `levelBodySize`: the body size the level gives.
    pub fn level_body_size(&self) -> f64 {
        text_at_level(12.0, 13.0, self.level)
    }

    /// `bodySize`: the font size, else the level's.
    pub fn body_size(&self) -> f64 {
        self.font_size.unwrap_or_else(|| self.level_body_size())
    }

    /// `textSize(compact:comfortable:)`.
    pub fn text_size(&self, compact: f64, comfortable: f64) -> f64 {
        if let Some(u) = self.uniform_scale() {
            let reference = reference_tokens();
            let reference_body = reference.body_size() * u;
            let adjustment = self.font_size.map(|f| f / reference_body).unwrap_or(1.0);
            return reference.text_size(compact, comfortable) * u * adjustment;
        }
        let at_level = text_at_level(compact, comfortable, self.level);
        match self.font_size {
            None => at_level,
            Some(f) => half(at_level * f / self.level_body_size()),
        }
    }

    /// `space(_:)`: a grid value times the spacing, on the half-point grid.
    pub fn space(&self, value: f64) -> f64 {
        if self.spacing == 1.0 { value } else { half(value * self.spacing) }
    }

    /// `fontToken(_:)`: a font token, rescaled by this body over its preset's.
    pub fn font_token(&self, key: &str) -> Option<f64> {
        let exact = self.token(key)?;
        let Some(preset) = self.based_on.as_deref().and_then(DensityPreset::from_raw) else {
            return Some(exact);
        };
        let preset_body = preset.tokens().body_size();
        Some(if preset_body > 0.0 { exact * self.body_size() / preset_body } else { exact })
    }
}

fn text_at_level(compact: f64, comfortable: f64, level: f64) -> f64 {
    if level == 0.0 {
        return compact;
    }
    if level == 1.0 {
        return comfortable;
    }
    half(compact + (comfortable - compact) * level)
}

/// `DensityPreset`: the built-in densities.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DensityPreset {
    /// `ultraCompact`.
    UltraCompact,
    /// `compact`.
    Compact,
    /// `cozy` (shown as Default).
    Cozy,
    /// `comfortable`.
    Comfortable,
    /// `spacious`.
    Spacious,
}

/// `DensityPreset.spaciousGapNudge`.
pub const SPACIOUS_GAP_NUDGE: f64 = 0.5;
/// `DensityPreset.compactTabToOmnibarExtra`.
pub const COMPACT_TAB_TO_OMNIBAR_EXTRA: f64 = 1.0;
/// `DensityPreset.chromeOmnibarHeight`.
pub const CHROME_OMNIBAR_HEIGHT: f64 = 34.0;
/// `DensityPreset.chromeToolbarGap`.
pub const CHROME_TOOLBAR_GAP: f64 = 6.0;
/// `DensityPreset.defaultStripPadding`.
pub const DEFAULT_STRIP_PADDING: f64 = 5.0;
/// `DensityPreset.defaultOmnibarCapHeight`.
pub const DEFAULT_OMNIBAR_CAP_HEIGHT: f64 = 11.0;
/// `DensityPreset.defaultStarPlateSize`.
pub const DEFAULT_STAR_PLATE_SIZE: f64 = 28.0;

impl DensityPreset {
    /// `allCases`, in order.
    pub const ALL: [DensityPreset; 5] = [
        DensityPreset::UltraCompact,
        DensityPreset::Compact,
        DensityPreset::Cozy,
        DensityPreset::Comfortable,
        DensityPreset::Spacious,
    ];

    /// `rawValue`.
    pub fn raw(self) -> &'static str {
        match self {
            DensityPreset::UltraCompact => "ultraCompact",
            DensityPreset::Compact => "compact",
            DensityPreset::Cozy => "cozy",
            DensityPreset::Comfortable => "comfortable",
            DensityPreset::Spacious => "spacious",
        }
    }

    /// `DensityPreset(rawValue:)`.
    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|p| p.raw() == raw)
    }

    /// `scaleFactor`.
    pub fn scale_factor(self) -> f64 {
        match self {
            DensityPreset::UltraCompact => 0.8,
            DensityPreset::Compact => 0.9,
            DensityPreset::Cozy => 1.0,
            DensityPreset::Comfortable => 1.1,
            DensityPreset::Spacious => 1.2,
        }
    }

    /// `rowHeight`: the browser row height.
    pub fn row_height(self) -> f64 {
        match self {
            DensityPreset::UltraCompact => 24.0,
            DensityPreset::Compact => 28.0,
            DensityPreset::Cozy => 30.0,
            DensityPreset::Comfortable => 32.0,
            DensityPreset::Spacious => 36.0,
        }
    }

    /// `name`: the shown name.
    pub fn name(self) -> &'static str {
        match self {
            DensityPreset::UltraCompact => "Ultra-compact",
            DensityPreset::Compact => "Compact",
            DensityPreset::Cozy => "Default",
            DensityPreset::Comfortable => "Comfortable",
            DensityPreset::Spacious => "Spacious",
        }
    }

    /// `starGlyphSides`: the bookmark star's side.
    pub fn star_glyph_side(self) -> f64 {
        match self {
            DensityPreset::UltraCompact => 21.0,
            DensityPreset::Compact => 23.5,
            DensityPreset::Cozy => 28.0,
            DensityPreset::Comfortable => 29.5,
            DensityPreset::Spacious => 32.0,
        }
    }

    /// `omnibarScaleFactor`: Default's omnibar is Compact's.
    pub fn omnibar_scale_factor(self) -> f64 {
        if self == DensityPreset::Cozy {
            DensityPreset::Compact.scale_factor()
        } else {
            self.scale_factor()
        }
    }

    /// `isOmnibarToken(_:)`.
    pub fn is_omnibar_token(key: &str) -> bool {
        key.starts_with("omnibar") || key == "toolbarGlyphSize"
    }

    /// `tokens`: the preset's density (computed once).
    pub fn tokens(self) -> &'static DensityTokens {
        static CACHE: [OnceLock<DensityTokens>; 5] =
            [OnceLock::new(), OnceLock::new(), OnceLock::new(), OnceLock::new(), OnceLock::new()];
        let index = Self::ALL.iter().position(|p| *p == self).unwrap_or(0);
        CACHE[index].get_or_init(|| self.build_tokens())
    }

    fn build_tokens(self) -> DensityTokens {
        let t = self.scale_factor();
        let reference = reference_tokens();
        let mut sizes: BTreeMap<String, f64> =
            reference.tokens.iter().map(|(k, v)| (k.clone(), half(v * t))).collect();
        for key in ["tabTitleSize", "sidebarTitleSize", "omnibarFontSize"] {
            match reference.token(key) {
                Some(v) => sizes.insert(key.into(), v * t),
                None => sizes.remove(key),
            };
        }
        for key in ["sidebarLineBoxBaseline", "omnibarLineBoxBaseline"] {
            match reference.token(key) {
                Some(v) => sizes.insert(key.into(), v),
                None => sizes.remove(key),
            };
        }
        let row = self.row_height();
        sizes.insert("densityScale".into(), t);
        sizes.insert("composerZoom".into(), t);
        sizes.insert("sidebarRowHeight".into(), row - half(2.0 * t));
        sizes.insert("browserRowHeight".into(), row);
        sizes.insert("tabStripHeight".into(), row + 2.0 * half(3.0 * t));
        if t >= 1.0 {
            let nudge = if self == DensityPreset::Spacious { SPACIOUS_GAP_NUDGE } else { 0.0 };
            let padding = half(DEFAULT_STRIP_PADDING * t) + nudge;
            sizes.insert("browserRowGap".into(), padding);
            sizes.insert("tabStripHeight".into(), row + 2.0 * padding);
            sizes.insert("omnibarRowGap".into(), half(CHROME_TOOLBAR_GAP * t) + nudge);
        }
        if self == DensityPreset::Compact {
            sizes.insert("tabToOmnibarGap".into(), half(3.0 * t) + COMPACT_TAB_TO_OMNIBAR_EXTRA);
        }
        if self == DensityPreset::Cozy {
            for (key, value) in &DensityPreset::Compact.tokens().tokens {
                if Self::is_omnibar_token(key) {
                    sizes.insert(key.clone(), *value);
                }
            }
            match sizes.get("omnibarHeight").copied() {
                Some(v) => sizes.insert("omnibarButtonSize".into(), v),
                None => sizes.remove("omnibarButtonSize"),
            };
            sizes.insert("omnibarStarPlateSize".into(), DEFAULT_STAR_PLATE_SIZE);
            sizes.insert("omnibarHeight".into(), CHROME_OMNIBAR_HEIGHT);
            sizes.insert("omnibarCornerRadius".into(), half(CHROME_OMNIBAR_HEIGHT * 8.0 / 28.0));
            sizes.insert("omnibarFontSize".into(), (DEFAULT_OMNIBAR_CAP_HEIGHT - 0.31) / 0.70459);
            if let Some(icon) = sizes.get("omnibarIconSize").copied() {
                sizes.insert("omnibarIconSize".into(), icon + 1.0);
            }
        }
        sizes.insert("omnibarStarGlyphSize".into(), self.star_glyph_side());
        DensityTokens::new(
            self.raw(),
            self.name(),
            None,
            (reference.level + 3.0) * t - 3.0,
            reference.spacing * t,
            reference.font_size.map(|f| f * t),
            sizes,
        )
    }
}

/// `DensityPreset.reference`: Default's unscaled sizes.
pub fn reference_values() -> BTreeMap<String, f64> {
    [
        ("sidebarRowHeight", 28.0),
        ("browserRowHeight", 30.0),
        ("browserRowGap", 3.0),
        ("tabStripHeight", 36.0),
        ("tabTitleSize", 14.0),
        ("sidebarTitleSize", 14.0),
        ("chatEditorMin", 35.0),
        ("sidebarContentInset", 7.0),
        ("sidebarLineBoxBaseline", 1.0),
        ("sidebarIconColumn", 16.5),
        ("sidebarIconGap", 7.0),
        ("tabIconSize", 16.5),
        ("tabIconTitleGap", 7.0),
        ("tabGap", 3.0),
        ("tabMaxWidth", 201.0),
        ("rowCornerRadius", 9.0),
        ("tabCornerRadius", 9.0),
        ("omnibarCornerRadius", 8.0 / 0.9),
        ("omnibarPopupCornerRadius", 12.0),
        ("omnibarPopupRowCornerRadius", 8.0),
        ("toolbarGlyphSize", 14.0 / 0.9 / 0.617),
        ("omnibarHeight", 28.0 / 0.9),
        ("omnibarFontSize", (10.0 - 0.31) / 0.70459 / 0.9),
        ("omnibarLineBoxBaseline", 1.0),
        ("omnibarButtonSpacing", 3.0),
        ("omnibarEdgeInset", 2.0),
        ("omnibarFieldTrailingGap", 5.0),
        ("omnibarTrailingPadding", 8.0),
        ("omnibarTrailingIconSize", 18.0),
        ("omnibarIconViewSize", 25.0),
        ("omnibarIconSize", 12.0 / 0.9 / 0.697),
        ("omnibarExtensionsGlyphSize", 27.0 / 0.9),
        ("omnibarMoreGlyphSize", 20.0 / 0.9),
        ("omnibarIconLeading", 2.0),
        ("omnibarTextGap", 5.0),
        ("omnibarPopupTopOutset", 3.0),
        ("omnibarPopupSideOutset", 7.0),
        ("omnibarPopupRowGap", 2.0),
        ("omnibarPopupBottomPadding", 4.0),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect()
}

/// `DensityPreset.referenceTokens`: Default's unscaled density (level 0.5, 14 pt body).
pub fn reference_tokens() -> &'static DensityTokens {
    static REFERENCE: OnceLock<DensityTokens> = OnceLock::new();
    REFERENCE.get_or_init(|| {
        DensityTokens::new("cozy", "Default", None, 0.5, 1.0, Some(14.0), reference_values())
    })
}

/// `Typography.userScale`: the Text Size override over the density's body, times the interface
/// scale (`interface_scale` is 1 while Interface Size is off).
pub fn user_scale(tokens: &DensityTokens, font_override: Option<f64>, interface_scale: f64) -> f64 {
    let configured = font_override.map(|body| body / tokens.body_size()).unwrap_or(1.0);
    configured * interface_scale
}

/// `Typography.sidebarTitleSize(_:)`.
pub fn sidebar_title_size(tokens: &DensityTokens) -> f64 {
    tokens.font_token("sidebarTitleSize").unwrap_or_else(|| tokens.text_size(12.0, 13.0))
}
