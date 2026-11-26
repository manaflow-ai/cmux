//! What a scan found, in the JSON the app's `ImportFinding` codes (`JSONEncoder.importJobs`:
//! camelCase keys, nil optionals left out).

use serde::{Deserialize, Serialize};

/// A kind of thing on this Mac that cmux can bring over (`ImportSourceKind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SourceKind {
    /// A browser's profiles: history, bookmarks, cookies.
    Browser,
    /// Claude Code's sessions (`~/.claude/projects`).
    ClaudeCode,
    /// Codex's threads (`~/.codex/sessions`).
    Codex,
    /// Ghostty's config, which cmux terminals already read.
    Ghostty,
    /// iTerm2's profiles (colors).
    Iterm2,
    /// cmux Classic's saved workspaces.
    CmuxClassic,
    /// Conductor's workspaces, adopted in place.
    Conductor,
}

impl SourceKind {
    /// Every kind, in `ImportSourceKind.allCases` order.
    pub const ALL: [SourceKind; 7] = [
        SourceKind::Browser,
        SourceKind::ClaudeCode,
        SourceKind::Codex,
        SourceKind::Ghostty,
        SourceKind::Iterm2,
        SourceKind::CmuxClassic,
        SourceKind::Conductor,
    ];

    /// Starting it reads another app's data into cmux (a browser's history, bookmarks and
    /// cookies; iTerm2's colors written as a theme), so a start that is not the person's own
    /// click in this app asks the person natively first.
    pub fn start_reads_another_app(self) -> bool {
        matches!(self, SourceKind::Browser | SourceKind::Iterm2)
    }

    /// The source's name when no scan names it (a job whose source went away).
    pub fn display_name(self) -> &'static str {
        match self {
            SourceKind::Browser => "",
            SourceKind::ClaudeCode => "Claude Code",
            SourceKind::Codex => "Codex",
            SourceKind::Ghostty => "Ghostty",
            SourceKind::Iterm2 => "iTerm2",
            SourceKind::CmuxClassic => "cmux Classic",
            SourceKind::Conductor => "Conductor",
        }
    }
}

/// One kind of browser data (`ImportDataKind`), in its `allCases` order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DataKind {
    Bookmarks,
    History,
    OpenTabs,
    Extensions,
    Passwords,
    Cookies,
    SearchEngines,
}

impl DataKind {
    /// `ImportDataKind.allCases`.
    pub const ALL: [DataKind; 7] = [
        DataKind::Bookmarks,
        DataKind::History,
        DataKind::OpenTabs,
        DataKind::Extensions,
        DataKind::Passwords,
        DataKind::Cookies,
        DataKind::SearchEngines,
    ];

    /// Its raw value, as fingerprints and the app's JSON spell it.
    pub fn raw(self) -> &'static str {
        match self {
            DataKind::Bookmarks => "bookmarks",
            DataKind::History => "history",
            DataKind::OpenTabs => "openTabs",
            DataKind::Extensions => "extensions",
            DataKind::Passwords => "passwords",
            DataKind::Cookies => "cookies",
            DataKind::SearchEngines => "searchEngines",
        }
    }
}

/// A browser engine family (`BrowserFamily`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Family {
    Chromium,
    Firefox,
    Safari,
    Webkit,
    #[default]
    Other,
}

/// What the browser registry (Swift's `browser-sources.json`) says about one browser, sent by
/// the app beside a finding or job that names it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BrowserFacts {
    pub family: Family,
    /// Its first bundle id, for the card's icon.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    /// The name people know it by ("Chrome").
    pub name: String,
}

/// Whether the source can be brought over now.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Access {
    /// One click imports it.
    #[default]
    Ready,
    /// macOS keeps the data behind Full Disk Access (Safari).
    NeedsFullDiskAccess,
    /// cmux already uses it as it is (Ghostty's config).
    InUse,
}

impl Access {
    pub fn raw(self) -> &'static str {
        match self {
            Access::Ready => "ready",
            Access::NeedsFullDiskAccess => "needsFullDiskAccess",
            Access::InUse => "inUse",
        }
    }
}

/// One profile of a browser or iTerm2, by its folder (or profile) name.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub directory_name: String,
    #[serde(default)]
    pub kinds: Vec<DataKind>,
}

impl Profile {
    pub fn new(directory_name: impl Into<String>, kinds: Vec<DataKind>) -> Self {
        Profile { directory_name: directory_name.into(), kinds }
    }
}

/// What a scan found for one source (`ImportFinding`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Finding {
    /// `browser.<id>`, `agents.claudeCode`, `agents.codex`, `terminal.ghostty`,
    /// `terminal.iterm2`, `cmux.classic`, `agents.conductor`.
    pub id: String,
    pub kind: SourceKind,
    /// The browser's raw id, for `.browser`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub browser: Option<String>,
    pub name: String,
    #[serde(default)]
    pub profiles: Vec<Profile>,
    /// Sessions, threads or workspaces. Nil only for cmux Classic before its count is known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub count: Option<i64>,
    #[serde(default)]
    pub access: Access,
}

impl Finding {
    /// A finding with no browser, no profiles, a zero count and ready access (Swift's defaults).
    pub fn new(id: impl Into<String>, kind: SourceKind, name: impl Into<String>) -> Self {
        Finding {
            id: id.into(),
            kind,
            browser: None,
            name: name.into(),
            profiles: Vec::new(),
            count: Some(0),
            access: Access::Ready,
        }
    }

    /// Nothing new to bring now (cmux Classic's saved session is all here already).
    pub fn offers_nothing_new(&self) -> bool {
        self.kind == SourceKind::CmuxClassic && self.count == Some(0)
    }

    /// Every kind any profile holds: history, bookmarks, then the rest in `DataKind` order.
    pub fn kinds(&self) -> Vec<DataKind> {
        let held =
            |kind: &DataKind| self.profiles.iter().any(|profile| profile.kinds.contains(kind));
        let mut order = vec![DataKind::History, DataKind::Bookmarks];
        order.extend(
            DataKind::ALL
                .into_iter()
                .filter(|kind| !matches!(kind, DataKind::History | DataKind::Bookmarks)),
        );
        order.into_iter().filter(held).collect()
    }

    /// What has to change for a dismissed card to come back: a new profile or kind of data, or
    /// the source appearing again. Counts that grow every day are left out on purpose.
    pub fn fingerprint(&self) -> String {
        let mut parts = vec![self.id.clone(), self.access.raw().to_owned()];
        if matches!(self.kind, SourceKind::Browser | SourceKind::Iterm2) {
            let mut held: Vec<String> = self
                .profiles
                .iter()
                .flat_map(|profile| {
                    profile
                        .kinds
                        .iter()
                        .map(move |kind| format!("{}={}", profile.directory_name, kind.raw()))
                })
                .collect();
            held.sort();
            parts.extend(held);
        }
        parts.join("|")
    }
}

/// What a run brought (`ImportCounts`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Counts {
    pub bookmarks: i64,
    pub history: i64,
    pub open_tabs: i64,
    pub extensions: i64,
    pub cookies: i64,
    pub passwords: i64,
    pub search_engines: i64,
}

impl std::ops::Add for Counts {
    type Output = Counts;
    fn add(self, other: Counts) -> Counts {
        Counts {
            bookmarks: self.bookmarks + other.bookmarks,
            history: self.history + other.history,
            open_tabs: self.open_tabs + other.open_tabs,
            extensions: self.extensions + other.extensions,
            cookies: self.cookies + other.cookies,
            passwords: self.passwords + other.passwords,
            search_engines: self.search_engines + other.search_engines,
        }
    }
}
