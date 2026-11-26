//! What the scan's file facts become (`ImportScanner`'s decisions). The app lists folders and
//! checks which files exist, cheaply and without asking; these rules say which browsers come
//! first, which folders are profiles, what each profile holds and which findings show.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::model::{Access, DataKind, Finding, Profile, SourceKind};

/// The most entries one folder listing counts, so a huge session folder costs a bounded scan.
pub const LISTING_LIMIT: usize = 20_000;

/// The browsers people most often come from lead; the rest keep registry order.
pub const LEADING: [&str; 8] =
    ["chrome", "arc", "safari", "zen", "firefox", "brave", "edge", "dia"];

/// The candidates (raw ids, registry order) in scan order.
pub fn browser_order(candidates: &[String]) -> Vec<String> {
    let rank =
        |raw: &str| LEADING.iter().position(|leading| *leading == raw).unwrap_or(LEADING.len());
    let mut ordered: Vec<(usize, &String)> = candidates.iter().enumerate().collect();
    ordered.sort_by_key(|(offset, raw)| (rank(raw), *offset));
    ordered.into_iter().map(|(_, raw)| raw.clone()).collect()
}

/// Inside `~/Library/Containers` or `~/Library/Group Containers`, where macOS guards each app's data.
pub fn is_container(path: &str) -> bool {
    path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/")
}

/// A folder listing's names the scan counts: hidden ones left out, at most [`LISTING_LIMIT`].
pub fn visible(names: &[String]) -> Vec<String> {
    names.iter().filter(|name| !name.starts_with('.')).take(LISTING_LIMIT).cloned().collect()
}

/// `Default` and `Profile N` folders, `Default` first, then by number.
pub fn chromium_profile_names(listing: &[String]) -> Vec<String> {
    let number =
        |name: &str| name.strip_prefix("Profile ").and_then(|rest| rest.parse::<i64>().ok());
    let mut names: Vec<String> = visible(listing)
        .into_iter()
        .filter(|name| name == "Default" || number(name).is_some())
        .collect();
    names.sort_by_key(|name| if name == "Default" { -1 } else { number(name).unwrap_or(i64::MAX) });
    names
}

/// Which files one Chromium profile folder holds, and what the registry says the browser keeps.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChromiumFacts {
    pub history: bool,
    /// The `Bookmarks` JSON file, and the browser keeps its bookmarks in that format.
    pub bookmarks_json: bool,
    /// Arc's sidebar file, beside the profiles.
    pub arc_sidebar: bool,
    /// `Network/Cookies` or `Cookies`.
    pub cookies: bool,
    /// A known Keychain item: without one the cookies cannot be read.
    pub safe_storage: bool,
}

pub fn chromium_kinds(facts: ChromiumFacts) -> Vec<DataKind> {
    let mut kinds = Vec::new();
    if facts.history {
        kinds.push(DataKind::History);
    }
    if facts.arc_sidebar || facts.bookmarks_json {
        kinds.push(DataKind::Bookmarks);
    }
    if facts.safe_storage && facts.cookies {
        kinds.push(DataKind::Cookies);
    }
    kinds
}

/// What one Firefox-family profile folder (`Profiles/<name>`) holds.
pub fn firefox_kinds(places: bool, cookies: bool) -> Vec<DataKind> {
    let mut kinds = Vec::new();
    if places {
        kinds.extend([DataKind::History, DataKind::Bookmarks]);
    }
    if cookies {
        kinds.push(DataKind::Cookies);
    }
    kinds
}

/// A Firefox-family browser's profile folders, sorted, as `Profiles/<name>`.
pub fn firefox_profile_names(listing: &[String]) -> Vec<String> {
    let mut names = visible(listing);
    names.sort();
    names.into_iter().map(|name| format!("Profiles/{name}")).collect()
}

/// A browser's finding from its profiles: the ones with data not imported before, or none.
/// `imported` holds `<browser>/<profile folder>` keys.
pub fn profiles_finding(
    raw: &str,
    name: &str,
    profiles: Vec<Profile>,
    imported: &BTreeSet<String>,
) -> Option<Finding> {
    let fresh: Vec<Profile> = profiles
        .into_iter()
        .filter(|profile| {
            !profile.kinds.is_empty()
                && !imported.contains(&format!("{raw}/{}", profile.directory_name))
        })
        .collect();
    if fresh.is_empty() {
        return None;
    }
    let mut finding = browser_finding(raw, name);
    finding.profiles = fresh;
    Some(finding)
}

fn browser_finding(raw: &str, name: &str) -> Finding {
    let mut finding = Finding::new(format!("browser.{raw}"), SourceKind::Browser, name);
    finding.browser = Some(raw.to_owned());
    finding
}

/// What opening a file says (`FileAccess`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FileAccess {
    Missing,
    Denied,
    Readable,
}

/// Safari from one probe of `History.db` (and of `Bookmarks.plist` when that reads).
pub fn safari_finding(
    raw: &str,
    name: &str,
    history: FileAccess,
    bookmarks_readable: bool,
    has_cookie_file: bool,
    imported: &BTreeSet<String>,
) -> Option<Finding> {
    let mut finding = browser_finding(raw, name);
    match history {
        FileAccess::Missing => None,
        FileAccess::Denied => {
            finding.profiles =
                vec![Profile::new("Safari", vec![DataKind::History, DataKind::Bookmarks])];
            finding.access = Access::NeedsFullDiskAccess;
            Some(finding)
        }
        FileAccess::Readable => {
            if imported.contains(&format!("{raw}/Safari")) {
                return None;
            }
            let mut kinds = vec![DataKind::History];
            if bookmarks_readable {
                kinds.push(DataKind::Bookmarks);
            }
            // The cookie file is in Safari's container: with Full Disk Access (History.db reads) it reads.
            if has_cookie_file {
                kinds.push(DataKind::Cookies);
            }
            finding.profiles = vec![Profile::new("Safari", kinds)];
            Some(finding)
        }
    }
}

/// Claude Code's sessions or Codex's threads, from the `.jsonl` names counted.
pub fn sessions_finding(kind: SourceKind, count: i64) -> Option<Finding> {
    let (id, name) = match kind {
        SourceKind::ClaudeCode => ("agents.claudeCode", "Claude Code"),
        SourceKind::Codex => ("agents.codex", "Codex"),
        _ => return None,
    };
    let mut finding = Finding::new(id, kind, name);
    finding.count = Some(count);
    (count > 0).then_some(finding)
}

/// The `.jsonl` names in one listing.
pub fn session_files(listing: &[String]) -> i64 {
    i64::try_from(visible(listing).iter().filter(|name| name.ends_with(".jsonl")).count())
        .unwrap_or(i64::MAX)
}

/// What Classic's file metadata and NEXT's migration ledger establish before consent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ClassicAvailability {
    Unavailable,
    Available,
    AlreadyImported,
}

/// cmux Classic, offered without reading its workspaces: its count is unknown until the preview.
pub fn classic_finding(availability: ClassicAvailability) -> Option<Finding> {
    let mut finding = Finding::new("cmux.classic", SourceKind::CmuxClassic, "cmux Classic");
    finding.count = match availability {
        ClassicAvailability::Unavailable => return None,
        ClassicAvailability::Available => None,
        ClassicAvailability::AlreadyImported => Some(0),
    };
    Some(finding)
}

/// Conductor's workspace folders, when they or its database are here.
pub fn conductor_finding(workspaces: i64, database_bytes: i64) -> Option<Finding> {
    if workspaces <= 0 && database_bytes <= 0 {
        return None;
    }
    let mut finding = Finding::new("agents.conductor", SourceKind::Conductor, "Conductor");
    finding.count = Some(workspaces.max(0));
    Some(finding)
}

/// Ghostty's config (any nonempty `config.ghostty` or `config`): cmux terminals already read it.
pub fn ghostty_finding(config_bytes: &[i64]) -> Option<Finding> {
    if !config_bytes.iter().any(|bytes| *bytes > 0) {
        return None;
    }
    let mut finding = Finding::new("terminal.ghostty", SourceKind::Ghostty, "Ghostty");
    finding.access = Access::InUse;
    Some(finding)
}

/// iTerm2's profiles, by name.
pub fn iterm2_finding(names: &[String]) -> Option<Finding> {
    if names.is_empty() {
        return None;
    }
    let mut finding = Finding::new("terminal.iterm2", SourceKind::Iterm2, "iTerm2");
    finding.profiles = names.iter().map(|name| Profile::new(name.clone(), vec![])).collect();
    finding.count = Some(i64::try_from(names.len()).unwrap_or(i64::MAX));
    Some(finding)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    #[test]
    fn leading_browsers_come_first_then_registry_order() {
        let order =
            browser_order(&strings(&["vivaldi", "firefox", "orion", "chrome", "safari", "zen"]));
        assert_eq!(order, ["chrome", "safari", "zen", "firefox", "vivaldi", "orion"]);
    }

    #[test]
    fn chrome_profiles_and_kinds_come_from_file_existence() {
        let names = chromium_profile_names(&strings(&[
            "Profile 2",
            "Default",
            "Guest Profile",
            "System Profile",
            "Local State",
            "Profile 1",
            "Profile x",
            ".Profile 3",
        ]));
        assert_eq!(names, ["Default", "Profile 1", "Profile 2"]);
        let all = ChromiumFacts {
            history: true,
            bookmarks_json: true,
            cookies: true,
            safe_storage: true,
            ..ChromiumFacts::default()
        };
        assert_eq!(
            chromium_kinds(all),
            [DataKind::History, DataKind::Bookmarks, DataKind::Cookies]
        );
        assert_eq!(
            chromium_kinds(ChromiumFacts {
                cookies: true,
                safe_storage: true,
                ..ChromiumFacts::default()
            }),
            [DataKind::Cookies]
        );
        // Without a known Keychain item the cookies cannot be read.
        assert_eq!(chromium_kinds(ChromiumFacts { cookies: true, ..ChromiumFacts::default() }), []);
        assert_eq!(
            chromium_kinds(ChromiumFacts { arc_sidebar: true, ..ChromiumFacts::default() }),
            [DataKind::Bookmarks]
        );
    }

    #[test]
    fn a_profile_imported_before_is_left_out() {
        let profiles = || {
            vec![
                Profile::new("Default", vec![DataKind::History]),
                Profile::new("Profile 1", vec![DataKind::History]),
            ]
        };
        let one = BTreeSet::from(["chrome/Default".to_owned()]);
        let chrome = profiles_finding("chrome", "Chrome", profiles(), &one).unwrap();
        assert_eq!(chrome.id, "browser.chrome");
        assert_eq!(chrome.browser.as_deref(), Some("chrome"));
        assert_eq!(
            chrome.profiles.iter().map(|p| p.directory_name.as_str()).collect::<Vec<_>>(),
            ["Profile 1"]
        );
        let both = BTreeSet::from(["chrome/Default".to_owned(), "chrome/Profile 1".to_owned()]);
        assert_eq!(profiles_finding("chrome", "Chrome", profiles(), &both), None);
        let empty = vec![Profile::new("Default", vec![])];
        assert_eq!(profiles_finding("chrome", "Chrome", empty, &BTreeSet::new()), None);
    }

    #[test]
    fn firefox_family_profiles_come_from_the_profiles_folder() {
        assert_eq!(
            firefox_profile_names(&strings(&["b.old", "ab12.Default (release)", ".DS_Store"])),
            ["Profiles/ab12.Default (release)", "Profiles/b.old"]
        );
        assert_eq!(
            firefox_kinds(true, true),
            [DataKind::History, DataKind::Bookmarks, DataKind::Cookies]
        );
        assert_eq!(firefox_kinds(false, false), []);
    }

    #[test]
    fn safari_behind_full_disk_access_is_found_without_reading_it() {
        let none = BTreeSet::new();
        let denied =
            safari_finding("safari", "Safari", FileAccess::Denied, false, true, &none).unwrap();
        assert_eq!(denied.access, Access::NeedsFullDiskAccess);
        assert_eq!(denied.kinds(), [DataKind::History, DataKind::Bookmarks]);
        assert_eq!(
            safari_finding("safari", "Safari", FileAccess::Missing, true, true, &none),
            None
        );
        let readable =
            safari_finding("safari", "Safari", FileAccess::Readable, true, true, &none).unwrap();
        assert_eq!(
            readable.profiles[0].kinds,
            [DataKind::History, DataKind::Bookmarks, DataKind::Cookies]
        );
        assert_eq!(readable.access, Access::Ready);
        let imported = BTreeSet::from(["safari/Safari".to_owned()]);
        assert_eq!(
            safari_finding("safari", "Safari", FileAccess::Readable, true, true, &imported),
            None
        );
    }

    #[test]
    fn agent_sessions_are_counted_from_listings() {
        assert_eq!(session_files(&strings(&["1.jsonl", "2.jsonl", "notes.txt", ".x.jsonl"])), 2);
        assert_eq!(
            sessions_finding(SourceKind::ClaudeCode, 3).map(|f| (f.id, f.count)),
            Some(("agents.claudeCode".into(), Some(3)))
        );
        assert_eq!(sessions_finding(SourceKind::Codex, 2).map(|f| f.name), Some("Codex".into()));
        assert_eq!(sessions_finding(SourceKind::Codex, 0), None);
        assert_eq!(sessions_finding(SourceKind::Ghostty, 2), None);
    }

    #[test]
    fn ghostty_is_in_use_and_classic_can_be_offered_without_reading_its_workspaces() {
        assert_eq!(ghostty_finding(&[0, 1]).map(|f| f.access), Some(Access::InUse));
        assert_eq!(ghostty_finding(&[0, 0]), None);
        let classic = classic_finding(ClassicAvailability::Available).unwrap();
        assert!(classic.count.is_none() && !classic.offers_nothing_new());
        let finished = classic_finding(ClassicAvailability::AlreadyImported).unwrap();
        assert!(finished.count == Some(0) && finished.offers_nothing_new());
        assert_eq!(classic_finding(ClassicAvailability::Unavailable), None);
    }

    #[test]
    fn conductor_counts_its_workspace_folders() {
        assert_eq!(
            conductor_finding(3, 0).map(|f| (f.id, f.count)),
            Some(("agents.conductor".into(), Some(3)))
        );
        assert_eq!(conductor_finding(0, 10).and_then(|f| f.count), Some(0));
        assert_eq!(conductor_finding(0, 0), None);
    }

    #[test]
    fn iterm2_lists_profiles_by_name() {
        let found = iterm2_finding(&strings(&["Work", "Default"])).unwrap();
        assert_eq!(found.count, Some(2));
        assert_eq!(found.profiles[1], Profile::new("Default", vec![]));
        assert_eq!(iterm2_finding(&[]), None);
    }

    #[test]
    fn containers_are_never_looked_in() {
        assert!(is_container("/Users/me/Library/Containers/com.apple.Safari/Data"));
        assert!(is_container("/Users/me/Library/Group Containers/x/y"));
        assert!(!is_container("/Users/me/Library/Application Support/Google/Chrome"));
    }
}
