//! The browser tab rules: the page fit and device emulation actions, and
//! which page Picture in Picture acts on and how its menu row reads.

use serde::{Deserialize, Serialize};

/// A fit the device menu offers, and the action that toggles it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FitAction {
    pub action: &'static str,
    /// The fit it toggles; none: `browserFit`, which sets the fit its argument names.
    pub fit: Option<&'static str>,
}

/// The fit actions.
pub fn fit_actions() -> Vec<FitAction> {
    vec![
        FitAction { action: "browserFitDesktop", fit: Some("16:9") },
        FitAction { action: "browserFitDesktop1280", fit: Some("1280") },
        FitAction { action: "browserFit", fit: None },
    ]
}

/// The daemon capability a fit needs: a width (`1280`) needs the width fit.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FitCapability {
    BrowserFit,
    BrowserFitWidth,
}

fn capability(fit: &str) -> FitCapability {
    if fit.parse::<i64>().is_ok() {
        FitCapability::BrowserFitWidth
    } else {
        FitCapability::BrowserFit
    }
}

/// Foundation's `.whitespaces`: spaces and tabs, not line breaks.
fn trim_spaces(text: &str) -> &str {
    text.trim_matches(|c: char| {
        c.is_whitespace()
            && !matches!(c, '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    })
}

/// A fit action's change.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "decision")]
pub enum Fit {
    /// The tab's fit after the action (none: off), and the capability it needs.
    Set { fit: Option<String>, capability: FitCapability },
    /// No fit was named.
    NoBrowser,
}

/// A fit action: `fixed` toggles one fit (off when the tab has it), else the
/// `asked` argument sets a fit (`off` clears it).
pub fn fit(fixed: Option<&str>, asked: Option<&str>, current: Option<&str>) -> Fit {
    let Some(asked) = fixed.or(asked.map(trim_spaces)).filter(|asked| !asked.is_empty()) else {
        return Fit::NoBrowser;
    };
    let off = asked.eq_ignore_ascii_case("off") || (fixed.is_some() && current == fixed);
    let next = (!off).then(|| asked.to_owned());
    let capability = next.as_deref().map_or(FitCapability::BrowserFit, capability);
    Fit::Set { fit: next, capability }
}

/// The fits the device menu offers on a daemon with these capabilities.
pub fn menu_fits(fit: bool, fit_width: bool) -> Vec<FitAction> {
    fit_actions()
        .into_iter()
        .filter(|action| match action.fit.map(capability) {
            Some(FitCapability::BrowserFit) => fit,
            Some(FitCapability::BrowserFitWidth) => fit_width,
            None => false,
        })
        .collect()
}

/// What Emulate Device does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "decision")]
pub enum Device {
    /// Emulates `device` (none: clear; empty: keep the device) in `orientation`.
    Emulate { device: Option<String>, orientation: Option<String> },
    /// No argument: the device menu.
    Menu,
}

/// Emulate Device: a `device` or `orientation` argument emulates at once
/// (`device: none` clears), else the menu shows.
pub fn device(device: Option<&str>, orientation: Option<&str>) -> Device {
    let device = device.map(trim_spaces);
    if device.is_none() && orientation.is_none() {
        return Device::Menu;
    }
    let device = match device {
        Some(device) if device.eq_ignore_ascii_case("none") => None,
        device => Some(device.unwrap_or_default().to_owned()),
    };
    Device::Emulate { device, orientation: orientation.map(str::to_owned) }
}

/// What the app knows of the pages Picture in Picture may act on.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PipFacts {
    /// The run names a tab (its target or `tab` argument).
    pub named: bool,
    /// That tab has a page on this Mac.
    pub named_page: bool,
    /// The run comes from the media card's menu.
    pub card: bool,
    /// The tab the media card shows plays a video.
    pub shown_video: bool,
    /// The focused pane's tab has a page.
    pub focused: bool,
    /// That page plays (or played) a video.
    pub focused_video: bool,
}

/// The page Picture in Picture acts on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "decision")]
pub enum PipPage {
    Named,
    Shown,
    Focused,
    /// The named tab has no web page.
    NeedsPage,
    NoVideo,
}

/// The named tab's page; from the media card's menu, the tab the card shows;
/// else the focused tab's when it shows a video; else the tab whose video the
/// card shows; else the focused tab's, whose script may still find a video.
pub fn pip_page(facts: PipFacts) -> PipPage {
    if facts.named {
        return if facts.named_page { PipPage::Named } else { PipPage::NeedsPage };
    }
    if facts.card {
        return if facts.shown_video { PipPage::Shown } else { PipPage::NoVideo };
    }
    if facts.focused && facts.focused_video {
        return PipPage::Focused;
    }
    if facts.shown_video {
        PipPage::Shown
    } else if facts.focused {
        PipPage::Focused
    } else {
        PipPage::NoVideo
    }
}

/// A Picture in Picture menu row's target.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PipTarget {
    /// No target: the media card's menu.
    #[default]
    Card,
    Tab,
    /// Any other target (a pane, a workspace).
    #[serde(other)]
    Other,
}

/// What a Picture in Picture menu row reads.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PipRowFacts {
    /// `media.pictureInPicture.enabled`.
    pub enabled: bool,
    pub target: PipTarget,
    /// The card's (or the tab's) video.
    pub video: bool,
    /// That video floats now.
    pub floating: bool,
}

/// A Picture in Picture menu row.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PipRow {
    pub hidden: bool,
    /// Reads Exit Picture in Picture.
    pub exit: bool,
}

/// A tab's menu offers the row on a page that plays (or played) a video, the
/// media card's while the card shows a video, any other target's always; on a
/// floating video it reads as Exit. Turned off, no menu offers it.
pub fn pip_row(facts: PipRowFacts) -> PipRow {
    let shows = facts.enabled && (facts.target == PipTarget::Other || facts.video);
    let exit = facts.target != PipTarget::Other && facts.floating;
    PipRow { hidden: !shows, exit }
}

#[cfg(test)]
#[path = "browser_tests.rs"]
mod tests;
