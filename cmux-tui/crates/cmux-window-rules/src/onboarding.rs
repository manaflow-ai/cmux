//! The onboarding tool window's rules: what its footer offers (the primary
//! button's title and action, Skip, Back, whether it can advance, the bar over
//! the explainers) and the Import from Browser step's selection rules (which
//! phases take edits, when Import can start, when Import Passwords from CSV
//! shows, the kinds offered and checked, Edge first).
//!
//! These were Swift in the macOS app (`OnboardingModel`, `ImportStepModel`);
//! the app keeps the window, the browser detection, the Keychain and the
//! Touch ID sheet, sends the step's facts (`window_onboarding_*` ops) and runs
//! the answer. The tool window shows one tool (Lawrence 2026-10-09: no
//! onboarding window, no sequence).

use serde::{Deserialize, Serialize};

/// The tool a window shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Step {
    Agents,
    ImportData,
    ComputerUse,
    MakeItYours,
}

/// The import step's phase, without its payload.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ImportPhase {
    #[default]
    Idle,
    Detecting,
    Ready,
    /// Explaining the folder grant for one browser, before the open panel.
    ExplainingAccess,
    /// Waiting for the person to agree to the password import.
    ConfirmingPasswords,
    Importing,
    Finished,
    Cancelled,
    Failed,
}

impl ImportPhase {
    /// Whether the profile and kind checkboxes take edits.
    pub fn can_edit_selection(self) -> bool {
        matches!(self, ImportPhase::Ready | ImportPhase::Cancelled | ImportPhase::Failed)
    }

    /// The bar over the explainers: allow access is half way, the Keychain
    /// explainer three quarters.
    pub fn explainer_progress(self) -> Option<f64> {
        match self {
            ImportPhase::ExplainingAccess => Some(0.5),
            ImportPhase::ConfirmingPasswords => Some(0.75),
            _ => None,
        }
    }
}

/// What the import step knows for its rules.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ImportFacts {
    pub phase: ImportPhase,
    /// Import was clicked under 600 ms ago: a repeated click is not a Continue.
    pub just_started: bool,
    /// The checked profiles and kinds make a plan with at least one item.
    pub has_plan: bool,
    /// The open panel is up for the browser being explained.
    pub requesting_access: bool,
    /// Touch ID (or the Mac's password) is up.
    pub authorizing: bool,
    /// The last Keychain confirmation did not complete.
    pub authorization_denied: bool,
    /// A listed profile has passwords this build cannot read (export only).
    pub export_only_passwords: bool,
    /// The finished import could not read some passwords.
    pub password_error: bool,
}

impl ImportFacts {
    /// Whether Import (or Begin Importing) can run now.
    pub fn can_start(self) -> bool {
        (self.phase.can_edit_selection() && self.has_plan)
            || (self.phase == ImportPhase::ConfirmingPasswords && !self.authorizing)
    }

    /// Whether Import Passwords from CSV… shows: an export-only profile, a
    /// Keychain confirmation that did not finish, or an import that could not
    /// read them.
    pub fn offers_password_csv(self) -> bool {
        match self.phase {
            ImportPhase::Idle
            | ImportPhase::Detecting
            | ImportPhase::Importing
            | ImportPhase::ExplainingAccess => false,
            ImportPhase::ConfirmingPasswords => self.authorization_denied,
            ImportPhase::Finished => self.export_only_passwords || self.password_error,
            ImportPhase::Ready | ImportPhase::Cancelled | ImportPhase::Failed => {
                self.export_only_passwords
            }
        }
    }
}

/// What the Computer Use step knows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ComputerUseFacts {
    pub all_granted: bool,
    /// The helper did not answer.
    pub helper_failed: bool,
}

/// The facts of one tool window.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub step: Step,
    #[serde(default)]
    pub import: ImportFacts,
    #[serde(default)]
    pub computer_use: ComputerUseFacts,
}

/// The primary button's title (the app localizes it).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PrimaryTitle {
    Detecting,
    FindBrowsers,
    Continue,
    BeginImporting,
    Import,
    Done,
}

/// What the primary button (Return) does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PrimaryAction {
    /// Nothing: a repeated click, or detection already in flight.
    None,
    /// Find the browsers.
    Detect,
    /// The explainer's Continue: the open panel at the browser's folder.
    ContinueAccess,
    /// Start the import (or show the Keychain explainer first).
    StartImport,
    /// Restart the Computer Use helper that did not answer.
    RestartHelper,
    /// Allow the next Computer Use permission.
    AllowNext,
    /// End the window as Done.
    Finish,
}

/// The footer's Back.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BackAction {
    /// From the folder explainer to the list, nothing read.
    CancelAccess,
    /// From the Keychain explainer to the list, nothing read.
    BackFromConsent,
}

/// The footer of one tool window.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Footer {
    pub primary_title: PrimaryTitle,
    pub primary: PrimaryAction,
    /// Skip, or Skip Importing on the Keychain explainer.
    pub skip_importing: bool,
    /// Back shows and acts (none hides it).
    pub back: Option<BackAction>,
    /// The primary button can run now.
    pub can_advance: bool,
    /// The bar over the explainers.
    pub flow_progress: Option<f64>,
    /// Skip (Escape) first leaves the Keychain explainer, reading nothing.
    pub skip_leaves_consent: bool,
    /// Skip on Make cmux Yours puts back the picks it made live.
    pub skip_reverts_choices: bool,
}

fn primary_title(window: &Window) -> PrimaryTitle {
    let import = window.import;
    match window.step {
        Step::ImportData => match import.phase {
            ImportPhase::Detecting => PrimaryTitle::Detecting,
            ImportPhase::Idle => PrimaryTitle::FindBrowsers,
            ImportPhase::ExplainingAccess => PrimaryTitle::Continue,
            ImportPhase::ConfirmingPasswords => PrimaryTitle::BeginImporting,
            _ if import.can_start() => PrimaryTitle::Import,
            _ => PrimaryTitle::Done,
        },
        Step::Agents | Step::MakeItYours => PrimaryTitle::Continue,
        Step::ComputerUse => PrimaryTitle::Done,
    }
}

fn primary(window: &Window) -> PrimaryAction {
    let import = window.import;
    match window.step {
        Step::ImportData if import.just_started => PrimaryAction::None,
        Step::ImportData => match import.phase {
            ImportPhase::Idle => PrimaryAction::Detect,
            // A slow privacy or filesystem probe must not turn Return into Done.
            ImportPhase::Detecting => PrimaryAction::None,
            ImportPhase::ExplainingAccess => PrimaryAction::ContinueAccess,
            // While Touch ID is up it waits, never ends the window.
            ImportPhase::ConfirmingPasswords if import.can_start() => PrimaryAction::StartImport,
            ImportPhase::ConfirmingPasswords => PrimaryAction::None,
            _ if import.can_start() => PrimaryAction::StartImport,
            _ => PrimaryAction::Finish,
        },
        Step::ComputerUse if !window.computer_use.all_granted => {
            if window.computer_use.helper_failed {
                PrimaryAction::RestartHelper
            } else {
                PrimaryAction::AllowNext
            }
        }
        _ => PrimaryAction::Finish,
    }
}

fn back(window: &Window) -> Option<BackAction> {
    if window.step != Step::ImportData {
        return None;
    }
    match window.import.phase {
        ImportPhase::ExplainingAccess if !window.import.requesting_access => {
            Some(BackAction::CancelAccess)
        }
        ImportPhase::ConfirmingPasswords if !window.import.authorizing => {
            Some(BackAction::BackFromConsent)
        }
        _ => None,
    }
}

/// The footer of `window`.
pub fn footer(window: &Window) -> Footer {
    let importing = window.step == Step::ImportData;
    let confirming = importing && window.import.phase == ImportPhase::ConfirmingPasswords;
    Footer {
        primary_title: primary_title(window),
        primary: primary(window),
        skip_importing: confirming,
        back: back(window),
        can_advance: !(importing && window.import.phase == ImportPhase::Detecting),
        flow_progress: if importing { window.import.phase.explainer_progress() } else { None },
        skip_leaves_consent: confirming,
        skip_reverts_choices: window.step == Step::MakeItYours,
    }
}

/// A kind of browser data the import step brings.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ImportKind {
    Bookmarks,
    History,
    OpenTabs,
    Extensions,
    Cookies,
    SearchEngines,
    Passwords,
}

/// The kinds every profile row shows.
pub const OFFERED: [ImportKind; 6] = [
    ImportKind::Bookmarks,
    ImportKind::History,
    ImportKind::OpenTabs,
    ImportKind::Extensions,
    ImportKind::Cookies,
    ImportKind::SearchEngines,
];

/// Offered unchecked: the search engine is one setting for every profile, and
/// open tabs and extensions open a workspace per profile, so each happens only
/// when asked.
pub const OPT_IN: [ImportKind; 3] =
    [ImportKind::OpenTabs, ImportKind::Extensions, ImportKind::SearchEngines];

/// The one line of checkboxes: passwords too when this build can save them.
pub fn kind_choices(password_store: bool) -> Vec<ImportKind> {
    let mut kinds = OFFERED.to_vec();
    if password_store {
        kinds.push(ImportKind::Passwords);
    }
    kinds
}

/// The kinds checked when the step opens: the offered ones but the opt-ins.
pub fn default_kinds() -> Vec<ImportKind> {
    OFFERED.into_iter().filter(|kind| !OPT_IN.contains(kind)).collect()
}

/// The kinds a preset checks (the cookie import card: cookies only):
/// passwords only when this build can save them. Sorted, deduplicated.
pub fn preset_kinds(preset: &[ImportKind], password_store: bool) -> Vec<ImportKind> {
    let mut kinds: Vec<ImportKind> = preset
        .iter()
        .copied()
        .filter(|&kind| kind != ImportKind::Passwords || password_store)
        .collect();
    kinds.sort();
    kinds.dedup();
    kinds
}

/// The Edge channels, stable first.
pub const EDGE: [&str; 4] = ["edge", "edgeBeta", "edgeDev", "edgeCanary"];

/// The detected browsers in list order: Edge leads, stable before its
/// channels (the browser people most often come from on a work Mac); the
/// rest keep detection order. Answers indices into `browsers`.
pub fn edge_first(browsers: &[String]) -> Vec<usize> {
    let rank = |name: &str| EDGE.iter().position(|edge| *edge == name);
    let mut edges: Vec<(usize, usize)> = browsers
        .iter()
        .enumerate()
        .filter_map(|(index, name)| rank(name).map(|rank| (rank, index)))
        .collect();
    edges.sort();
    edges
        .into_iter()
        .map(|(_, index)| index)
        .chain(browsers.iter().enumerate().filter(|(_, name)| rank(name).is_none()).map(|(i, _)| i))
        .collect()
}

#[cfg(test)]
#[path = "onboarding_tests.rs"]
mod tests;
