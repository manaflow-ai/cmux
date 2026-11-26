//! Settings › Import's cards (`ImportCardDeck`): the agents' requests first, then jobs by
//! phase, then what the scan found. Words are keys the app renders from its string table
//! ([`Text`], [`Label`]); the order, states, buttons and counts are decided here.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::job::{Failure, Job, Ledger, Pause, Phase};
use crate::model::{Access, BrowserFacts, DataKind, Family, Finding, SourceKind};
use crate::request::Request;
use crate::state::State;

/// What a card's button does (`ImportCardAction`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    Start,
    Resume,
    Retry,
    Dismiss,
    Restore,
    More,
    Open,
    Hide,
}

impl Action {
    pub const ALL: [Action; 8] = [
        Action::Start,
        Action::Resume,
        Action::Retry,
        Action::Dismiss,
        Action::Restore,
        Action::More,
        Action::Open,
        Action::Hide,
    ];

    /// It reads another app's data (start, resume, retry).
    pub fn starts_work(self) -> bool {
        matches!(self, Action::Start | Action::Resume | Action::Retry)
    }

    /// The word on the native confirm sheet's button for it.
    pub fn confirm_label(self) -> Label {
        match self {
            Action::Resume => Label::Resume,
            Action::Retry => Label::Retry,
            _ => Label::Import,
        }
    }
}

/// A button's word, by its `importSuggestions.*` string.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Label {
    Import,
    ShowChats,
    ImportWorkspaces,
    ImportAgain,
    ImportColors,
    OpenConfig,
    OpenSystemSettings,
    OpenAppearance,
    More,
    NotNow,
    ShowAgain,
    Resume,
    Retry,
    Done,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Button {
    pub action: Action,
    pub label: Label,
}

const fn button(action: Action, label: Label) -> Button {
    Button { action, label }
}

/// A card's text, by its `importSuggestions.*` string and the values it takes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "key", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Text {
    /// Shown as is (a source's own name).
    Literal {
        value: String,
    },
    Empty,
    // Facts.
    NeedsFullDiskAccess,
    /// The kinds, as a list ("History, Bookmarks and Cookies").
    Kinds {
        kinds: Vec<DataKind>,
    },
    /// "2 profiles · History and Bookmarks".
    ProfilesAndKinds {
        profiles: usize,
        kinds: Vec<DataKind>,
    },
    Sessions {
        count: i64,
    },
    Threads {
        count: i64,
    },
    Workspaces {
        count: i64,
    },
    Profiles {
        count: i64,
    },
    ClassicAllHere,
    InUse,
    /// "Requested by the Chief".
    RequestedByChief,
    // Benefits.
    SafariAccess,
    BrowserSignedIn {
        name: String,
    },
    BrowserHistory {
        name: String,
    },
    ClaudeCode,
    Codex,
    Classic,
    ClassicAgain,
    Conductor,
    Iterm2,
    Ghostty,
    Request {
        site: String,
    },
    // Titles.
    RequestTitle {
        browser: String,
        site: String,
    },
    // Statuses.
    Running,
    NeedsPerson,
    Interrupted,
    Declined,
    SourceGone,
    Failed,
    DoneChats,
    DoneTheme,
    DoneClassic,
    DoneConductor,
    DoneNothing,
    /// The button word "Done" (an accepted settings import that opened no workspace).
    Done,
    ImportedSessions {
        count: i64,
    },
    /// "Done: 10 pages, 3 bookmarks and 4 sign-ins"; only the nonzero counts are shown.
    DoneCounts {
        pages: i64,
        bookmarks: i64,
        cookies: i64,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CardState {
    Ready,
    Running,
    Paused,
    Done,
    Failed,
    Info,
}

/// One card, before the app puts words on it (`ImportCard`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Card {
    pub id: String,
    pub kind: SourceKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    pub title: Text,
    pub facts: Text,
    pub benefit: Text,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// The Chief raised it (the app names the Chief).
    pub requested_by_chief: bool,
    pub state: CardState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<Text>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub primary: Option<Button>,
    pub secondary: Vec<Button>,
    pub dismissed: bool,
}

/// Everything the cards come from.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Deck {
    pub findings: Vec<Finding>,
    pub state: State,
    pub jobs: Ledger,
    /// Finding id to the bundle id of its app, for the card's icon.
    pub apps: BTreeMap<String, String>,
    /// Browser raw id to what the registry says about it.
    pub browsers: BTreeMap<String, BrowserFacts>,
}

impl Deck {
    pub fn cards(&self) -> Vec<Card> {
        let mut cards = Vec::new();
        let mut placed = BTreeSet::new();
        // The Chief's requests lead: they answer something the person just ran into.
        for request in &self.state.requests {
            let id = request.id();
            if self.jobs.job(&id).is_none() {
                cards.push(self.request_card(request));
                placed.insert(id);
            }
        }
        // Jobs: running and paused first, then failed, then finished; newest first in each.
        let order = |phase: Phase| match phase {
            Phase::Running => 0,
            Phase::Paused => 1,
            Phase::Failed => 2,
            Phase::Done => 3,
        };
        let mut jobs: Vec<&Job> = self.jobs.jobs.iter().collect();
        jobs.sort_by(|a, b| {
            order(a.phase).cmp(&order(b.phase)).then(b.updated_at.total_cmp(&a.updated_at))
        });
        for job in jobs {
            if !placed.insert(job.id.clone()) {
                continue;
            }
            cards.push(
                self.job_card(job, self.findings.iter().find(|finding| finding.id == job.id)),
            );
        }
        for finding in &self.findings {
            if !placed.contains(&finding.id) {
                cards.push(self.finding_card(finding, self.state.hides(finding)));
            }
        }
        cards
    }

    fn browser(&self, raw: Option<&str>) -> Option<&BrowserFacts> {
        raw.and_then(|raw| self.browsers.get(raw))
    }

    fn app(&self, finding: &Finding) -> Option<String> {
        if let Some(raw) = finding.browser.as_deref() {
            return self
                .apps
                .get(&finding.id)
                .cloned()
                .or_else(|| self.browser(Some(raw)).and_then(|facts| facts.app.clone()));
        }
        self.apps.get(&finding.id).cloned()
    }

    fn facts(&self, finding: &Finding) -> Text {
        match finding.kind {
            SourceKind::Browser => {
                if finding.access == Access::NeedsFullDiskAccess {
                    return Text::NeedsFullDiskAccess;
                }
                // Safari has one store, no profiles to count.
                if self.browser(finding.browser.as_deref()).map(|facts| facts.family)
                    == Some(Family::Safari)
                {
                    return Text::Kinds { kinds: finding.kinds() };
                }
                Text::ProfilesAndKinds { profiles: finding.profiles.len(), kinds: finding.kinds() }
            }
            SourceKind::ClaudeCode => Text::Sessions { count: finding.count.unwrap_or(0) },
            SourceKind::Codex => Text::Threads { count: finding.count.unwrap_or(0) },
            SourceKind::CmuxClassic => match finding.count {
                None => Text::Empty,
                Some(_) if finding.offers_nothing_new() => Text::ClassicAllHere,
                Some(count) => Text::Workspaces { count },
            },
            SourceKind::Conductor => Text::Workspaces { count: finding.count.unwrap_or(0) },
            SourceKind::Iterm2 => Text::Profiles { count: finding.count.unwrap_or(0) },
            SourceKind::Ghostty => Text::InUse,
        }
    }

    fn benefit(finding: &Finding) -> Text {
        match finding.kind {
            SourceKind::Browser => {
                if finding.access == Access::NeedsFullDiskAccess {
                    Text::SafariAccess
                } else if finding.kinds().contains(&DataKind::Cookies) {
                    Text::BrowserSignedIn { name: finding.name.clone() }
                } else {
                    Text::BrowserHistory { name: finding.name.clone() }
                }
            }
            SourceKind::ClaudeCode => Text::ClaudeCode,
            SourceKind::Codex => Text::Codex,
            SourceKind::CmuxClassic if finding.offers_nothing_new() => Text::ClassicAgain,
            SourceKind::CmuxClassic => Text::Classic,
            SourceKind::Conductor => Text::Conductor,
            SourceKind::Iterm2 => Text::Iterm2,
            SourceKind::Ghostty => Text::Ghostty,
        }
    }

    /// The button that starts a source's import.
    pub fn start_button(kind: SourceKind) -> Button {
        match kind {
            SourceKind::Browser => button(Action::Start, Label::Import),
            SourceKind::ClaudeCode | SourceKind::Codex => button(Action::Start, Label::ShowChats),
            SourceKind::CmuxClassic | SourceKind::Conductor => {
                button(Action::Start, Label::ImportWorkspaces)
            }
            SourceKind::Iterm2 => button(Action::Start, Label::ImportColors),
            SourceKind::Ghostty => button(Action::Open, Label::OpenConfig),
        }
    }

    fn finding_card(&self, finding: &Finding, dismissed: bool) -> Card {
        let mut primary = if finding.offers_nothing_new() {
            button(Action::Start, Label::ImportAgain)
        } else {
            Self::start_button(finding.kind)
        };
        let mut state = CardState::Ready;
        match finding.access {
            Access::NeedsFullDiskAccess => {
                primary = button(Action::Open, Label::OpenSystemSettings);
                state = CardState::Info;
            }
            Access::InUse => state = CardState::Info,
            Access::Ready => {}
        }
        let mut secondary = Vec::new();
        if finding.kind == SourceKind::Browser && finding.access == Access::Ready {
            secondary.push(button(Action::More, Label::More));
        }
        if dismissed {
            secondary.push(button(Action::Restore, Label::ShowAgain));
        } else if finding.access != Access::InUse {
            secondary.push(button(Action::Dismiss, Label::NotNow));
        }
        Card {
            id: finding.id.clone(),
            kind: finding.kind,
            app: self.app(finding),
            title: Text::Literal { value: finding.name.clone() },
            facts: self.facts(finding),
            benefit: Self::benefit(finding),
            reason: None,
            requested_by_chief: false,
            state,
            progress: None,
            status: None,
            primary: Some(primary),
            secondary,
            dismissed,
        }
    }

    fn request_card(&self, request: &Request) -> Card {
        let facts = self.browser(Some(&request.browser));
        Card {
            id: request.id(),
            kind: SourceKind::Browser,
            app: self
                .apps
                .get(&format!("browser.{}", request.browser))
                .cloned()
                .or_else(|| facts.and_then(|facts| facts.app.clone())),
            title: Text::RequestTitle {
                browser: facts.map(|facts| facts.name.clone()).unwrap_or_default(),
                site: request.site.clone(),
            },
            facts: Text::RequestedByChief,
            benefit: Text::Request { site: request.site.clone() },
            reason: (!request.reason.is_empty()).then(|| request.reason.clone()),
            requested_by_chief: true,
            state: CardState::Ready,
            progress: None,
            status: None,
            primary: Some(button(Action::Start, Label::Import)),
            secondary: vec![button(Action::Dismiss, Label::NotNow)],
            dismissed: false,
        }
    }

    fn job_card(&self, job: &Job, finding: Option<&Finding>) -> Card {
        let facts = self.browser(job.browser.as_deref());
        let name = finding
            .map(|finding| finding.name.clone())
            .or_else(|| facts.map(|facts| facts.name.clone()))
            .unwrap_or_else(|| job.kind.display_name().to_owned());
        let title = match &job.site {
            Some(site) => Text::RequestTitle { browser: name, site: site.clone() },
            None => Text::Literal { value: name },
        };
        let benefit = match (&job.site, finding) {
            (Some(site), _) => Text::Request { site: site.clone() },
            (None, Some(finding)) => Self::benefit(finding),
            (None, None) => Text::Empty,
        };
        let mut card = Card {
            id: job.id.clone(),
            kind: job.kind,
            app: facts
                .and_then(|facts| facts.app.clone())
                .or_else(|| finding.and_then(|finding| self.app(finding))),
            title,
            facts: finding.map_or(Text::Empty, |finding| self.facts(finding)),
            benefit,
            reason: None,
            requested_by_chief: false,
            state: CardState::Running,
            progress: Some(job.fraction()),
            status: None,
            primary: None,
            secondary: Vec::new(),
            dismissed: false,
        };
        match job.phase {
            Phase::Running => card.status = Some(Text::Running),
            Phase::Paused => {
                card.state = CardState::Paused;
                card.status = Some(if job.pause == Some(Pause::NeedsPerson) {
                    Text::NeedsPerson
                } else {
                    Text::Interrupted
                });
                card.primary = Some(button(Action::Resume, Label::Resume));
                card.secondary = vec![button(Action::Hide, Label::NotNow)];
            }
            Phase::Failed => {
                card.state = CardState::Failed;
                card.progress = None;
                card.status = Some(match job.failure {
                    Some(Failure::Declined) => Text::Declined,
                    Some(Failure::SourceGone) => Text::SourceGone,
                    Some(Failure::ImportFailed) | None => Text::Failed,
                });
                card.primary = Some(button(Action::Retry, Label::Retry));
                card.secondary = vec![button(Action::Hide, Label::NotNow)];
            }
            Phase::Done => {
                card.state = CardState::Done;
                card.progress = None;
                card.status = Some(done_status(job));
                card.primary = match job.kind {
                    SourceKind::ClaudeCode | SourceKind::Codex => {
                        Some(button(Action::Open, Label::ShowChats))
                    }
                    SourceKind::Iterm2 => Some(button(Action::Open, Label::OpenAppearance)),
                    // Again while the source's data is here; its ledger brings nothing twice.
                    SourceKind::CmuxClassic | SourceKind::Conductor => {
                        finding.map(|_| button(Action::Start, Label::ImportAgain))
                    }
                    SourceKind::Browser | SourceKind::Ghostty => None,
                };
                card.secondary = vec![button(Action::Hide, Label::Done)];
            }
        }
        card
    }
}

/// What a finished job says it did.
pub fn done_status(job: &Job) -> Text {
    match job.kind {
        SourceKind::ClaudeCode | SourceKind::Codex => Text::DoneChats,
        SourceKind::Iterm2 => Text::DoneTheme,
        // An accepted settings import can succeed without opening a workspace.
        SourceKind::CmuxClassic => match job.opened {
            Some(0) => Text::Done,
            Some(count) => Text::ImportedSessions { count },
            None => Text::DoneClassic,
        },
        SourceKind::Conductor => Text::DoneConductor,
        SourceKind::Ghostty => Text::DoneNothing,
        SourceKind::Browser => {
            let counts = job.counts;
            if counts.history <= 0 && counts.bookmarks <= 0 && counts.cookies <= 0 {
                Text::DoneNothing
            } else {
                Text::DoneCounts {
                    pages: counts.history.max(0),
                    bookmarks: counts.bookmarks.max(0),
                    cookies: counts.cookies.max(0),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::job::Ledger;
    use crate::model::{Counts, Profile};
    use crate::request;

    const NOW: f64 = 1_800_000_000_000.0;

    fn browsers() -> BTreeMap<String, BrowserFacts> {
        let facts = |family, app: &str, name: &str| BrowserFacts {
            family,
            app: Some(app.into()),
            name: name.into(),
        };
        BTreeMap::from([
            ("chrome".into(), facts(Family::Chromium, "com.google.Chrome", "Chrome")),
            ("safari".into(), facts(Family::Safari, "com.apple.Safari", "Safari")),
            ("firefox".into(), facts(Family::Firefox, "org.mozilla.firefox", "Firefox")),
        ])
    }

    fn browser(raw: &str, name: &str, profiles: Vec<Profile>) -> Finding {
        let mut finding = Finding::new(format!("browser.{raw}"), SourceKind::Browser, name);
        finding.browser = Some(raw.into());
        finding.profiles = profiles;
        finding
    }

    fn chrome() -> Finding {
        browser(
            "chrome",
            "Chrome",
            vec![
                Profile::new(
                    "Default",
                    vec![DataKind::History, DataKind::Bookmarks, DataKind::Cookies],
                ),
                Profile::new("Profile 1", vec![DataKind::History, DataKind::Passwords]),
            ],
        )
    }

    fn claude() -> Finding {
        let mut finding = Finding::new("agents.claudeCode", SourceKind::ClaudeCode, "Claude Code");
        finding.count = Some(412);
        finding
    }

    fn safari() -> Finding {
        let mut finding =
            browser("safari", "Safari", vec![Profile::new("Safari", vec![DataKind::History])]);
        finding.access = Access::NeedsFullDiskAccess;
        finding
    }

    fn ghostty() -> Finding {
        let mut finding = Finding::new("terminal.ghostty", SourceKind::Ghostty, "Ghostty");
        finding.access = Access::InUse;
        finding
    }

    fn classic_all_here() -> Finding {
        Finding::new("cmux.classic", SourceKind::CmuxClassic, "cmux Classic")
    }

    fn deck(findings: Vec<Finding>, state: State, jobs: Ledger) -> Deck {
        Deck { findings, state, jobs, apps: BTreeMap::new(), browsers: browsers() }
    }

    fn actions(buttons: &[Button]) -> Vec<Action> {
        buttons.iter().map(|button| button.action).collect()
    }

    #[test]
    fn settings_lists_everything_found() {
        let cards =
            deck(vec![chrome(), safari(), ghostty()], State::default(), Ledger::default()).cards();
        assert_eq!(
            cards.iter().map(|card| card.id.as_str()).collect::<Vec<_>>(),
            ["browser.chrome", "browser.safari", "terminal.ghostty"]
        );
        assert_eq!(cards[0].primary, Some(button(Action::Start, Label::Import)));
        assert_eq!(actions(&cards[0].secondary), [Action::More, Action::Dismiss]);
        assert_eq!(
            cards[0].facts,
            Text::ProfilesAndKinds {
                profiles: 2,
                kinds: vec![
                    DataKind::History,
                    DataKind::Bookmarks,
                    DataKind::Passwords,
                    DataKind::Cookies
                ]
            }
        );
        assert_eq!(cards[0].benefit, Text::BrowserSignedIn { name: "Chrome".into() });
        assert_eq!(cards[0].app.as_deref(), Some("com.google.Chrome"));
        assert_eq!(
            (cards[1].state, cards[1].primary),
            (CardState::Info, Some(button(Action::Open, Label::OpenSystemSettings)))
        );
        assert_eq!(
            (cards[1].facts.clone(), cards[1].benefit.clone()),
            (Text::NeedsFullDiskAccess, Text::SafariAccess)
        );
        assert_eq!(cards[2].state, CardState::Info);
        assert!(cards[2].secondary.is_empty());
        assert_eq!(cards[2].primary, Some(button(Action::Open, Label::OpenConfig)));
    }

    #[test]
    fn safari_lists_kinds_without_profiles() {
        let mut readable = safari();
        readable.access = Access::Ready;
        let card = &deck(vec![readable], State::default(), Ledger::default()).cards()[0];
        assert_eq!(card.facts, Text::Kinds { kinds: vec![DataKind::History] });
        assert_eq!(card.benefit, Text::BrowserHistory { name: "Safari".into() });
    }

    #[test]
    fn a_dismissed_card_stays_gone_until_something_new_appears() {
        let mut state = State::default();
        state.dismiss(&chrome());
        state.dismiss(&claude());
        let dismissed = |findings: Vec<Finding>| {
            deck(findings, state.clone(), Ledger::default())
                .cards()
                .into_iter()
                .filter(|card| card.dismissed)
                .map(|card| card.id)
                .collect::<Vec<_>>()
        };
        assert_eq!(dismissed(vec![chrome(), claude()]), ["browser.chrome", "agents.claudeCode"]);
        let mut grown = claude();
        grown.count = Some(900);
        let mut new_profile = chrome();
        new_profile.profiles.push(Profile::new("Profile 2", vec![DataKind::History]));
        assert_eq!(dismissed(vec![new_profile, grown]), ["agents.claudeCode"]);
        let mut fewer = chrome();
        fewer.profiles.truncate(1);
        fewer.profiles[0].kinds.truncate(1);
        assert_eq!(dismissed(vec![fewer]), ["browser.chrome"]);
        let settings = deck(vec![claude()], state.clone(), Ledger::default()).cards();
        assert!(settings[0].dismissed);
        assert_eq!(actions(&settings[0].secondary), [Action::Restore]);
    }

    #[test]
    fn a_chief_request_leads_and_names_its_site() {
        let mut state = State::default();
        let site = request::site("https://GitHub.com/login").unwrap();
        state.raise(Request::new("chrome", site, "The page asks to sign in.", NOW));
        let cards = deck(vec![chrome()], state, Ledger::default()).cards();
        assert_eq!(
            cards.iter().map(|card| card.id.as_str()).collect::<Vec<_>>(),
            ["request.cookies.chrome.github.com", "browser.chrome"]
        );
        assert_eq!(cards[0].reason.as_deref(), Some("The page asks to sign in."));
        assert_eq!(
            cards[0].title,
            Text::RequestTitle { browser: "Chrome".into(), site: "github.com".into() }
        );
        assert!(cards[0].requested_by_chief);
        assert_eq!(cards[0].facts, Text::RequestedByChief);
        assert_eq!(actions(&cards[0].secondary), [Action::Dismiss]);
        let mut quiet = State::default();
        quiet.raise(Request::new("chrome", "x.com", "  ", NOW));
        assert_eq!(deck(vec![], quiet, Ledger::default()).cards()[0].reason, None);
    }

    #[test]
    fn a_request_with_a_job_shows_as_the_job() {
        let mut state = State::default();
        let request = Request::new("chrome", "x.com", "why", NOW);
        state.raise(request.clone());
        let mut jobs = Ledger::default();
        jobs.put(Job::from_request(&request, "Default", NOW));
        let cards = deck(vec![], state, jobs).cards();
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].state, CardState::Running);
        assert_eq!(
            cards[0].title,
            Text::RequestTitle { browser: "Chrome".into(), site: "x.com".into() }
        );
        assert_eq!(cards[0].benefit, Text::Request { site: "x.com".into() });
        assert_eq!(cards[0].status, Some(Text::Running));
        assert_eq!(cards[0].progress, Some(0.0));
    }

    #[test]
    fn only_start_resume_and_retry_read_another_apps_data() {
        assert_eq!(
            Action::ALL.into_iter().filter(|action| action.starts_work()).collect::<Vec<_>>(),
            [Action::Start, Action::Resume, Action::Retry]
        );
        assert_eq!(Action::Resume.confirm_label(), Label::Resume);
        assert_eq!(Action::Retry.confirm_label(), Label::Retry);
        assert_eq!(Action::Start.confirm_label(), Label::Import);
        let asks: Vec<SourceKind> =
            SourceKind::ALL.into_iter().filter(|kind| kind.start_reads_another_app()).collect();
        assert_eq!(asks, [SourceKind::Browser, SourceKind::Iterm2]);
    }

    #[test]
    fn settings_lists_every_card() {
        let many = (0..8)
            .map(|index| {
                let mut finding =
                    Finding::new(format!("agents.{index}"), SourceKind::Codex, "Codex");
                finding.count = Some(1);
                finding
            })
            .collect();
        let cards = deck(many, State::default(), Ledger::default()).cards();
        assert_eq!(cards.len(), 8);
        assert_eq!(cards[0].facts, Text::Threads { count: 1 });
    }

    #[test]
    fn settings_keeps_classic_once_everything_came_over() {
        let card = &deck(vec![classic_all_here()], State::default(), Ledger::default()).cards()[0];
        assert_eq!((card.id.as_str(), card.state), ("cmux.classic", CardState::Ready));
        assert_eq!(card.primary, Some(button(Action::Start, Label::ImportAgain)));
        assert_eq!(
            (card.facts.clone(), card.benefit.clone()),
            (Text::ClassicAllHere, Text::ClassicAgain)
        );
        let mut more = classic_all_here();
        more.count = Some(2);
        let first = &deck(vec![more], State::default(), Ledger::default()).cards()[0];
        assert_eq!(first.primary, Some(button(Action::Start, Label::ImportWorkspaces)));
        assert_eq!(
            (first.facts.clone(), first.benefit.clone()),
            (Text::Workspaces { count: 2 }, Text::Classic)
        );
        let mut unknown = classic_all_here();
        unknown.count = None;
        assert_eq!(
            deck(vec![unknown], State::default(), Ledger::default()).cards()[0].facts,
            Text::Empty
        );
    }

    #[test]
    fn a_finished_classic_import_offers_it_again_in_settings() {
        let mut job = Job::from_finding(&classic_all_here(), NOW);
        job.imported_classic(0, NOW);
        let mut ledger = Ledger::default();
        ledger.put(job.clone());
        let settings = &deck(vec![classic_all_here()], State::default(), ledger.clone()).cards()[0];
        assert_eq!(settings.state, CardState::Done);
        assert_eq!(settings.primary, Some(button(Action::Start, Label::ImportAgain)));
        assert_eq!(settings.status, Some(Text::Done));
        job.imported_classic(2, NOW);
        ledger.put(job.clone());
        let again = &deck(vec![classic_all_here()], State::default(), ledger.clone()).cards()[0];
        assert_eq!(again.status, Some(Text::ImportedSessions { count: 2 }));
        let gone = &deck(vec![], State::default(), ledger.clone()).cards()[0];
        assert_eq!((gone.state, gone.primary), (CardState::Done, None));
        assert_eq!(
            (gone.title.clone(), gone.facts.clone(), gone.benefit.clone()),
            (Text::Literal { value: "cmux Classic".into() }, Text::Empty, Text::Empty)
        );
        job.opened = None;
        assert_eq!(done_status(&job), Text::DoneClassic);
    }

    #[test]
    fn conductor_card_imports_workspaces_and_offers_it_again() {
        let mut finding = Finding::new("agents.conductor", SourceKind::Conductor, "Conductor");
        finding.count = Some(3);
        let card = &deck(vec![finding.clone()], State::default(), Ledger::default()).cards()[0];
        assert_eq!(card.primary, Some(button(Action::Start, Label::ImportWorkspaces)));
        assert_eq!(
            (card.facts.clone(), card.benefit.clone()),
            (Text::Workspaces { count: 3 }, Text::Conductor)
        );
        let mut job = Job::from_finding(&finding, NOW);
        job.imported_classic(3, NOW);
        let mut ledger = Ledger::default();
        ledger.put(job);
        let done = &deck(vec![finding], State::default(), ledger).cards()[0];
        assert_eq!((done.state, done.status.clone()), (CardState::Done, Some(Text::DoneConductor)));
        assert_eq!(done.primary, Some(button(Action::Start, Label::ImportAgain)));
    }

    #[test]
    fn a_running_job_shows_progress_and_finishes_with_its_counts() {
        let mut job = Job::from_finding(&chrome(), NOW);
        job.progressed(0.5, NOW);
        let mut ledger = Ledger::default();
        ledger.put(job.clone());
        let running = &deck(vec![], State::default(), ledger.clone()).cards()[0];
        assert_eq!(
            (running.state, running.progress, running.primary),
            (CardState::Running, Some(0.25), None)
        );
        assert_eq!(running.title, Text::Literal { value: "Chrome".into() });
        job.finished_step(
            0,
            Counts { bookmarks: 3, history: 10, cookies: 4, ..Counts::default() },
            NOW,
        );
        job.finished_step(1, Counts { history: 2, ..Counts::default() }, NOW);
        ledger.put(job);
        let card = &deck(vec![], State::default(), ledger.clone()).cards()[0];
        assert_eq!((card.state, card.progress), (CardState::Done, None));
        assert_eq!(card.secondary, vec![button(Action::Hide, Label::Done)]);
        assert_eq!(card.status, Some(Text::DoneCounts { pages: 12, bookmarks: 3, cookies: 4 }));
        assert_eq!(card.primary, None);
        let listed = deck(vec![chrome()], State::default(), ledger).cards();
        assert_eq!(listed.len(), 1);
        assert_eq!((listed[0].id.as_str(), listed[0].state), ("browser.chrome", CardState::Done));
        assert_eq!(listed[0].benefit, Text::BrowserSignedIn { name: "Chrome".into() });
    }

    #[test]
    fn jobs_sort_by_phase_then_newest() {
        let mut ledger = Ledger::default();
        let job = |id: &str, at: f64| Job::new(id, SourceKind::Codex, None, None, vec![], at);
        let mut done = job("done", 9.0);
        done.finished_step(0, Counts::default(), 9.0);
        let mut failed = job("failed", 8.0);
        failed.failed(Failure::SourceGone, 8.0);
        let mut paused = job("paused", 1.0);
        paused.paused(Pause::NeedsPerson, 1.0);
        for each in [done, failed, paused, job("old", 2.0), job("new", 3.0)] {
            ledger.put(each);
        }
        let cards = deck(vec![], State::default(), ledger).cards();
        assert_eq!(
            cards.iter().map(|card| card.id.as_str()).collect::<Vec<_>>(),
            ["new", "old", "paused", "failed", "done"]
        );
        assert_eq!(cards[2].status, Some(Text::NeedsPerson));
        assert_eq!(cards[3].status, Some(Text::SourceGone));
        assert_eq!(cards[3].primary, Some(button(Action::Retry, Label::Retry)));
        assert_eq!(cards[3].progress, None);
        assert_eq!(cards[4].status, Some(Text::DoneChats));
        assert_eq!(cards[4].primary, Some(button(Action::Open, Label::ShowChats)));
        assert_eq!(cards[4].title, Text::Literal { value: "Codex".into() });
    }

    #[test]
    fn a_job_cut_off_by_a_quit_is_paused() {
        let mut ledger = Ledger::default();
        let mut chrome = Job::from_finding(&chrome(), NOW);
        chrome.finished_step(1, Counts::default(), NOW);
        ledger.put(chrome);
        let mut relaunched = Ledger::read(&serde_json::to_vec(&ledger).unwrap());
        relaunched.relaunched(NOW);
        let card = &deck(vec![], State::default(), relaunched).cards()[0];
        assert_eq!(
            (card.state, card.primary),
            (CardState::Paused, Some(button(Action::Resume, Label::Resume)))
        );
        assert_eq!(card.status, Some(Text::Interrupted));
        assert_eq!(card.secondary, vec![button(Action::Hide, Label::NotNow)]);
    }

    #[test]
    fn finished_states_by_kind() {
        let finish = |kind: SourceKind| {
            let mut job = Job::new("x", kind, None, None, vec![], NOW);
            job.finished_step(0, Counts::default(), NOW);
            job
        };
        assert_eq!(done_status(&finish(SourceKind::Iterm2)), Text::DoneTheme);
        assert_eq!(done_status(&finish(SourceKind::Ghostty)), Text::DoneNothing);
        assert_eq!(done_status(&finish(SourceKind::Browser)), Text::DoneNothing);
        let mut ledger = Ledger::default();
        ledger.put(finish(SourceKind::Iterm2));
        assert_eq!(
            deck(vec![], State::default(), ledger).cards()[0].primary,
            Some(button(Action::Open, Label::OpenAppearance))
        );
    }

    #[test]
    fn the_app_comes_from_the_apps_map_first() {
        let mut deck = deck(vec![chrome(), claude()], State::default(), Ledger::default());
        assert_eq!(deck.cards()[1].app, None);
        deck.apps.insert("browser.chrome".into(), "com.google.Chrome.beta".into());
        deck.apps.insert("agents.claudeCode".into(), "com.anthropic.claudefordesktop".into());
        let cards = deck.cards();
        assert_eq!(cards[0].app.as_deref(), Some("com.google.Chrome.beta"));
        assert_eq!(cards[1].app.as_deref(), Some("com.anthropic.claudefordesktop"));
    }

    #[test]
    fn cards_speak_camel_case_json() {
        let card = &deck(vec![claude()], State::default(), Ledger::default()).cards()[0];
        let json = serde_json::to_value(card).unwrap();
        assert_eq!(json["facts"], serde_json::json!({"key": "sessions", "count": 412}));
        assert_eq!(json["primary"], serde_json::json!({"action": "start", "label": "showChats"}));
        assert_eq!(json["requestedByChief"], false);
        let deck: Deck = serde_json::from_value(
            serde_json::json!({"findings": [{"id": "a", "kind": "codex", "name": "Codex"}]}),
        )
        .unwrap();
        assert_eq!(deck.findings[0].count, None);
    }
}
