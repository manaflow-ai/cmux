//! The rules of the app's server handlers: Add Server…'s headless approval
//! (a person action with an explicit code and the server's four words) and
//! the app's ledger of the fixes the privileged helper applied, which Stop
//! Serving reverts. Pure: the app owns the cloud calls, the helper and the
//! 0600 atomic file write. Was `ServerHeadlessApproval.swift`,
//! `ServerFixLedger.swift` and `ServerHealthFixer.swift`'s tables.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

/// The words as typed, in order: case and separators (spaces, commas,
/// hyphens, anything not a letter) ignored.
pub fn words(text: Option<&str>) -> Vec<String> {
    text.unwrap_or_default()
        .to_lowercase()
        .split(|c: char| !c.is_alphabetic())
        .filter(|word| !word.is_empty())
        .map(str::to_owned)
        .collect()
}

/// A server waiting with a code (`PairingCandidate`), as the approval reads it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub code: String,
    pub name: String,
    /// The fingerprint words the app derived from the server's key.
    pub words: Vec<String>,
    /// The approver's team ids; the first is the one approved into.
    #[serde(default)]
    pub teams: Vec<String>,
    #[serde(default)]
    pub is_chief_brain: bool,
}

/// Why a headless approval approved nothing. The app shows the localized
/// text; none of them echoes the expected words.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Refusal {
    /// `refusal.server.pairWordsMissing`.
    WordsMissing,
    /// `refusal.server.pairWordsDiffer`.
    WordsDiffer,
    /// `refusal.server.pairNotFound`.
    NotFound,
}

/// Where one approval is.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Approval {
    /// The normalized code.
    pub code: String,
    pub typed: Vec<String>,
    pub name: Option<String>,
    pub run_chief: Option<bool>,
    pub candidate: Option<Candidate>,
    /// The approve intent was sent; its settle ends the approval.
    pub approving: bool,
}

/// What the approval hears.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum ApprovalEvent {
    /// The run starts: `code` already normalized (`PairingCode.normalize`).
    Start {
        code: String,
        words: Option<String>,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        run_chief: Option<bool>,
    },
    /// The source's candidate changed (nil: none).
    Candidate { found: Option<Candidate> },
    /// The lookup intent settled, with the source's refusal text if any.
    LookupSettled { reject: Option<String> },
    /// The approve intent settled.
    ApproveSettled { reject: Option<String> },
    /// The source's events ended before a settle.
    Ended,
}

/// What the app does next.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum ApprovalEffect {
    /// Keep listening.
    Wait,
    /// Send `lookupCode(code)`.
    Lookup { code: String },
    /// Send `approveCode(code, team, name, placeChief)`.
    Approve { code: String, team: String, name: String, place_chief: bool },
    /// Done: approved when both are none; else the refusal kind or the
    /// source's own refusal text.
    Finish { refusal: Option<Refusal>, reject: Option<String> },
}

impl ApprovalEffect {
    fn refuse(refusal: Refusal) -> Self {
        Self::Finish { refusal: Some(refusal), reject: None }
    }

    fn reject(reject: Option<String>) -> Self {
        Self::Finish { refusal: None, reject }
    }
}

/// One step of a headless approval: the approval as it now stands and what
/// the app does next.
pub fn approval_step(mut state: Approval, event: ApprovalEvent) -> (Approval, ApprovalEffect) {
    let effect = match event {
        ApprovalEvent::Start { code, words: typed, name, run_chief } => {
            let typed = words(typed.as_deref());
            if typed.is_empty() {
                ApprovalEffect::refuse(Refusal::WordsMissing)
            } else {
                state =
                    Approval { code: code.clone(), typed, name, run_chief, ..Approval::default() };
                ApprovalEffect::Lookup { code }
            }
        }
        ApprovalEvent::Candidate { found: Some(found) } if found.code == state.code => {
            state.candidate = Some(found);
            ApprovalEffect::Wait
        }
        ApprovalEvent::Candidate { .. } => ApprovalEffect::Wait,
        ApprovalEvent::LookupSettled { reject: Some(reject) } => {
            ApprovalEffect::reject(Some(reject))
        }
        ApprovalEvent::LookupSettled { reject: None } => approve(&mut state),
        ApprovalEvent::ApproveSettled { reject } if state.approving => {
            ApprovalEffect::reject(reject)
        }
        ApprovalEvent::ApproveSettled { .. } => ApprovalEffect::Wait,
        ApprovalEvent::Ended => ApprovalEffect::refuse(Refusal::NotFound),
    };
    (state, effect)
}

fn approve(state: &mut Approval) -> ApprovalEffect {
    let Some(found) = &state.candidate else { return ApprovalEffect::refuse(Refusal::NotFound) };
    let Some(team) = found.teams.first() else { return ApprovalEffect::refuse(Refusal::NotFound) };
    let expected: Vec<String> = found.words.iter().map(|word| word.to_lowercase()).collect();
    if state.typed != expected {
        return ApprovalEffect::refuse(Refusal::WordsDiffer);
    }
    let label = state.name.as_deref().map(str::trim).unwrap_or_default();
    let effect = ApprovalEffect::Approve {
        code: state.code.clone(),
        team: team.clone(),
        name: if label.is_empty() { found.name.clone() } else { label.to_owned() },
        place_chief: state.run_chief.unwrap_or(found.is_chief_brain),
    };
    state.approving = true;
    effect
}

/// The helper's allowlisted fixes (`ServerFix`), in allowlist order, with the
/// health check each belongs to.
pub const FIXES: [(&str, &str); 4] = [
    ("pmset.ac.sleep.0", "sleep.enabled"),
    ("pmset.ac.disksleep.0", "sleep.enabled"),
    ("pmset.autorestart.1", "restart.noAutoRestart"),
    ("pmset.ac.womp.1", "sleep.enabled"),
];

/// The fixes of `check`, in allowlist order; none: the check has no
/// automatic fix.
pub fn fixes_for(check: &str) -> Vec<&'static str> {
    FIXES.iter().filter(|(_, owner)| *owner == check).map(|(id, _)| *id).collect()
}

/// The app's own Fix button for a check (its title is app text, never the
/// server's: the click runs the allowlist).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalFix {
    /// The `Server` table key of the title.
    pub title_key: &'static str,
    pub needs_admin: bool,
}

/// The local Fix button of `check`, if the app fixes it itself.
pub fn local_fix(check: &str) -> Option<LocalFix> {
    match check {
        "sleep.enabled" => Some(LocalFix { title_key: "server.fix.sleep", needs_admin: true }),
        "restart.noAutoRestart" => {
            Some(LocalFix { title_key: "server.fix.autoRestart", needs_admin: true })
        }
        _ => None,
    }
}

/// What the fix ledger file holds.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Ledger {
    /// The recorded fixes, in allowlist order.
    Fixes { fixes: Vec<String> },
    /// The file cannot be read.
    Unknown,
    /// It names a fix this build cannot revert (a newer build's).
    Foreign,
}

impl Ledger {
    /// The fixes Stop Serving reverts, in allowlist order: every fix when the
    /// contents are not known (fail safe).
    pub fn to_revert(&self) -> Vec<String> {
        match self {
            Ledger::Fixes { fixes } => fixes.clone(),
            Ledger::Unknown | Ledger::Foreign => {
                FIXES.iter().map(|(id, _)| (*id).to_owned()).collect()
            }
        }
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct LedgerFile {
    version: i64,
    /// Fix id -> apply time in ms since 1970.
    fixes: BTreeMap<String, i64>,
}

fn parse(text: &str) -> Option<LedgerFile> {
    serde_json::from_str(text).ok()
}

/// What `text` holds (none: the file is missing, an empty ledger).
pub fn ledger(text: Option<&str>) -> Ledger {
    let Some(text) = text else { return Ledger::Fixes { fixes: Vec::new() } };
    let Some(file) = parse(text) else { return Ledger::Unknown };
    if file.fixes.keys().any(|id| !FIXES.iter().any(|(known, _)| known == id)) {
        return Ledger::Foreign;
    }
    let recorded: BTreeSet<&str> = file.fixes.keys().map(String::as_str).collect();
    Ledger::Fixes {
        fixes: FIXES
            .iter()
            .filter(|(id, _)| recorded.contains(id))
            .map(|(id, _)| (*id).to_owned())
            .collect(),
    }
}

/// A ledger edit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LedgerEdit {
    /// Add a fix before the helper is asked to apply it (kept time if there).
    Record,
    /// Remove a fix after its revert.
    Clear,
    /// Empty the ledger after every fix was reverted (also an unreadable one).
    Reset,
}

/// The file text to write after `edit` of `fix` at `now_ms`; none: nothing to
/// write (an unreadable ledger stays as it is, so nothing is lost; a clear of
/// a fix it lacks changes nothing). Foreign ids are kept.
pub fn ledger_edit(text: Option<&str>, edit: LedgerEdit, fix: &str, now_ms: i64) -> Option<String> {
    let mut file = match (edit, text) {
        (LedgerEdit::Reset, _) | (_, None) => LedgerFile::default(),
        (_, Some(text)) => parse(text)?,
    };
    file.version = 1;
    match edit {
        LedgerEdit::Record => {
            file.fixes.entry(fix.to_owned()).or_insert(now_ms);
        }
        LedgerEdit::Clear => {
            file.fixes.remove(fix)?;
        }
        LedgerEdit::Reset => {}
    }
    serde_json::to_string(&file).ok()
}

#[cfg(test)]
#[path = "server_tests.rs"]
mod tests;
