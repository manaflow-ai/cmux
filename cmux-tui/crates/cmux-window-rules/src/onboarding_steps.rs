//! The first-run window's step rules, moved out of the app's Swift step
//! models (`ComputerUseStepModel`, `AgentsStepModel` and the page state's
//! Computer Use rows): which grant's Allow is the primary action, what a
//! grants read, an Allow, a Restart or the panel's back button change, and
//! which agents the Agents step lists, which offer Sign In or Install and
//! what a finished install does next. Pure: the app reads the helper's
//! grants and acpmux's agents, opens System Settings, runs the installer and
//! the login, and asks here what follows.
//!
//! The footer and the Import step's rules are the `onboarding` module's.

use serde::{Deserialize, Serialize};

/// A grant the Computer Use helper needs, in row order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Pane {
    Accessibility,
    ScreenRecording,
}

/// The rows, in order: the first one missing is the primary one.
pub const PANES: [Pane; 2] = [Pane::Accessibility, Pane::ScreenRecording];

/// The helper's grants as it last reported them (Swift
/// `ComputerUsePermissions`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Grants {
    pub accessibility: bool,
    pub screen_recording: bool,
    /// The helper speaks another protocol: no Allow can help.
    pub helper_version_mismatch: bool,
    /// Computer Use is turned off: an Allow turns it on first.
    pub is_off: bool,
    /// The helper did not answer setup: only Restart helps.
    pub helper_failed: bool,
    /// The grants are still being read: missing ones may only look missing.
    pub is_reading: bool,
}

impl Grants {
    pub fn granted(&self, pane: Pane) -> bool {
        match pane {
            Pane::Accessibility => self.accessibility,
            Pane::ScreenRecording => self.screen_recording,
        }
    }

    /// No Allow can help: the helper failed or speaks another protocol.
    fn helpless(&self) -> bool {
        self.helper_failed || self.helper_version_mismatch
    }
}

/// The Computer Use window's state the app keeps between events.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ComputerUse {
    pub grants: Grants,
    /// A grants read came in since the window opened.
    pub received: bool,
    /// The list the drag panel is helping with, while it shows.
    pub helping: Option<Pane>,
    /// Allow found no Developer ID signed helper: Computer Use is
    /// unavailable in this build.
    pub unavailable: bool,
    /// The grants the person pressed Allow on in this window.
    pub allowed_here: Vec<Pane>,
    /// A grant an entry asked for before the first grants read came in.
    pub pending_allow: Option<Pane>,
    /// The app has a grants source (none in a build without the helper).
    pub source: bool,
    /// The source has a Developer ID signed helper app to drag in.
    pub helper: bool,
}

/// What happened in the window.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Event {
    /// The helper reported its grants.
    Grants { grants: Grants },
    /// A row's Allow.
    Allow { pane: Pane },
    /// An entry that opens the window at one grant (the palette's Grant
    /// actions, Settings' Grant Access).
    AllowOnceKnown { pane: Pane },
    /// Return in the window: the primary row's Allow.
    AllowNext,
    /// Restart a helper that did not answer setup.
    Restart,
    /// The drag panel's back button.
    DismissHelper,
    /// The window closed or the step left.
    Stop,
}

/// What the done view's close timer does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Timer {
    /// Start it unless it already runs (`doneDelay`, then the window closes).
    Schedule,
    Cancel,
}

/// A row's Allow control on the page.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Control {
    Hidden,
    Done,
    AllowPrimary,
    Allow,
}

/// The footer's one line on why Allow cannot help.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Note {
    HelperFailed,
    HelperVersionMismatch,
    Unavailable,
    Off,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub pane: Pane,
    pub control: Control,
}

/// What the window shows from its state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    /// The first grant still missing, in row order; none when every grant
    /// is on or no Allow can help.
    pub next_pane: Option<Pane>,
    /// The row whose Allow is the filled primary button: the next missing
    /// one, unless its drag panel already shows or Computer Use is
    /// unavailable.
    pub primary: Option<Pane>,
    pub all_granted: bool,
    /// Every grant is on after the person allowed one here: the done view.
    pub finished: bool,
    /// Screen Recording turned on after the person allowed it here.
    pub confirms_capture: bool,
    pub rows: Vec<Row>,
    pub note: Option<Note>,
}

/// An event's answer: the new state, what the app does, in this order
/// (comeback, enable, open the pane, restart, the timer), and the view.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub state: ComputerUse,
    /// The window comes back to the front (a grant landed while its panel
    /// showed, or the panel's back button closed it).
    pub comeback: bool,
    /// Turn Computer Use on (an Allow while it was off).
    pub enable: bool,
    /// Open this pane in System Settings, with the drag panel docked to it.
    pub open_settings: Option<Pane>,
    /// Restart the helper.
    pub restart: bool,
    pub timer: Option<Timer>,
    /// `AllowNext` found a primary row.
    pub accepted: bool,
    pub view: View,
}

impl ComputerUse {
    pub fn next_pane(&self) -> Option<Pane> {
        if self.grants.helpless() {
            return None;
        }
        PANES.into_iter().find(|pane| !self.grants.granted(*pane))
    }

    pub fn is_primary(&self, pane: Pane) -> bool {
        self.next_pane() == Some(pane) && self.helping != Some(pane) && !self.unavailable
    }

    pub fn all_granted(&self) -> bool {
        let grants = &self.grants;
        !grants.is_off && !grants.helpless() && PANES.into_iter().all(|pane| grants.granted(pane))
    }

    pub fn finished(&self) -> bool {
        self.all_granted() && !self.allowed_here.is_empty()
    }

    pub fn confirms_capture(&self) -> bool {
        self.allowed_here.contains(&Pane::ScreenRecording)
            && self.grants.screen_recording
            && !self.grants.helpless()
    }

    pub fn control(&self, pane: Pane) -> Control {
        if self.grants.helpless() {
            Control::Hidden
        } else if self.grants.granted(pane) {
            Control::Done
        } else if self.is_primary(pane) {
            Control::AllowPrimary
        } else {
            Control::Allow
        }
    }

    pub fn note(&self) -> Option<Note> {
        if self.grants.helper_failed {
            Some(Note::HelperFailed)
        } else if self.grants.helper_version_mismatch {
            Some(Note::HelperVersionMismatch)
        } else if self.unavailable {
            Some(Note::Unavailable)
        } else if self.grants.is_off {
            Some(Note::Off)
        } else {
            None
        }
    }

    pub fn view(&self) -> View {
        View {
            next_pane: self.next_pane(),
            primary: PANES.into_iter().find(|pane| self.is_primary(*pane)),
            all_granted: self.all_granted(),
            finished: self.finished(),
            confirms_capture: self.confirms_capture(),
            rows: PANES.into_iter().map(|pane| Row { pane, control: self.control(pane) }).collect(),
            note: self.note(),
        }
    }
}

/// The effects an event gathers before its outcome is read.
#[derive(Default)]
struct Effects {
    comeback: bool,
    enable: bool,
    open_settings: Option<Pane>,
    restart: bool,
    timer: Option<Timer>,
    accepted: bool,
}

/// Applies `event` to `state` (Swift `ComputerUseStepModel`'s `apply`,
/// `allow`, `allowOnceKnown`, `allowNext`, `restart`, `dismissHelper`,
/// `stop`).
pub fn computer_use(state: &ComputerUse, event: Event) -> Outcome {
    let mut state = state.clone();
    let mut effects = Effects::default();
    match event {
        Event::Grants { grants } => {
            state.grants = grants;
            state.received = true;
            if grants.helper_failed {
                state.helping = None;
            }
            if let Some(pane) = state.helping
                && grants.granted(pane)
            {
                state.helping = None;
                effects.comeback = true;
            }
            // An entry's Allow waits until the helper answered: grants still
            // being read look missing.
            if let Some(pane) = state.pending_allow
                && !grants.is_reading
            {
                state.pending_allow = None;
                if state.next_pane().is_some() {
                    allow(&mut state, &mut effects, pane);
                }
            }
            effects.timer = Some(if state.finished() { Timer::Schedule } else { Timer::Cancel });
        }
        Event::Allow { pane } => allow(&mut state, &mut effects, pane),
        Event::AllowOnceKnown { pane } => {
            if !state.received || state.grants.is_reading {
                state.pending_allow = Some(pane);
            } else if state.next_pane().is_some() && state.helping != Some(pane) {
                allow(&mut state, &mut effects, pane);
            }
        }
        Event::AllowNext => {
            if let Some(pane) = state.next_pane()
                && state.is_primary(pane)
            {
                allow(&mut state, &mut effects, pane);
                effects.accepted = true;
            }
        }
        Event::Restart => {
            if state.grants.helper_failed {
                state.unavailable = false;
                state.helping = None;
                effects.restart = state.source;
            }
        }
        Event::DismissHelper => {
            if state.helping.is_some() {
                state.helping = None;
                effects.comeback = true;
            }
        }
        Event::Stop => {
            state.helping = None;
            state.pending_allow = None;
            effects.timer = Some(Timer::Cancel);
        }
    }
    let view = state.view();
    Outcome {
        state,
        comeback: effects.comeback,
        enable: effects.enable,
        open_settings: effects.open_settings,
        restart: effects.restart,
        timer: effects.timer,
        accepted: effects.accepted,
        view,
    }
}

/// Allow: the pane in System Settings, with the drag panel docked to it.
/// Without a signed helper there is nothing a grant would help: Computer Use
/// is unavailable in this build.
fn allow(state: &mut ComputerUse, effects: &mut Effects, pane: Pane) {
    if !state.source || state.grants.granted(pane) {
        return;
    }
    if !state.helper {
        state.unavailable = true;
        state.helping = None;
        return;
    }
    state.unavailable = false;
    // Computer Use is off: the person's Allow turns it on, so the helper that
    // needs the grant starts and its rows turn Done by themselves.
    effects.enable = state.grants.is_off;
    effects.open_settings = Some(pane);
    if !state.allowed_here.contains(&pane) {
        state.allowed_here.push(pane);
    }
    state.helping = Some(pane);
}

/// An agent CLI's sign-in, as acpmux reports it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Auth {
    SignedIn,
    SignedOut,
    Expired,
    #[default]
    Unknown,
}

/// One agent acpmux reported (the app keeps its name and mark).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Agent {
    pub id: String,
    pub auth: Auth,
    /// Its CLI is on this Mac.
    pub installed: bool,
}

/// The vendors' own install pages for the agents cmux can install
/// (`acpmux harness install`), shown beside Install; any other agent has
/// none and is not listed when missing.
pub const INSTALL_PAGES: [(&str, &str); 2] = [
    ("claude", "https://docs.anthropic.com/en/docs/claude-code/setup"),
    ("codex", "https://developers.openai.com/codex/cli"),
];

/// An install that finished but whose agent the next read does not find.
pub const INSTALLED_NOT_FOUND: &str =
    "installed, but cmux does not find it yet; reopen cmux to look again";
/// An Install with no agents service to run it.
pub const NO_AGENTS_SERVICE: &str = "cmux could not reach its agents service";

pub fn install_page(id: &str) -> Option<&'static str> {
    INSTALL_PAGES.iter().find(|(agent, _)| *agent == id).map(|(_, page)| *page)
}

/// The Agents step's facts: the last read and what the person did here.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AgentsFacts {
    /// The agents as read, in acpmux's order.
    pub agents: Vec<Agent>,
    /// The agent whose Sign In ran last.
    pub signing_in: Option<String>,
    /// The install whose read has not landed yet.
    pub install_awaiting_read: Option<String>,
    /// Agents whose login opened in a terminal tab here.
    pub logins_opened: Vec<String>,
    /// Agents whose login opened here that the person said are signed in.
    pub confirmed_logins: Vec<String>,
    /// An Install is running.
    pub installing: bool,
}

/// One agent's buttons and state.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Marks {
    /// Sign In shows: installed and not known to be signed in.
    pub offers_sign_in: bool,
    /// Signed in, or unknown with its login confirmed here.
    pub counts_as_signed_in: bool,
    /// A login opened here reads as unknown and is not yet confirmed.
    pub awaits_confirmation: bool,
    /// Install runs when pressed: it is listed as installable and no other
    /// Install is running.
    pub can_install: bool,
}

/// How a read ends the install that waited for it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum FinishInstall {
    /// The agent is not found: the failure stays beside its button.
    Failed { message: String },
    /// The install's state clears and the agent's Sign In runs.
    SignIn,
}

/// What the Agents step lists from a read.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentsView {
    /// The installed agents, as indices into the read.
    pub listed: Vec<usize>,
    /// The missing agents cmux can install, as indices into the read.
    pub installable: Vec<usize>,
    /// Each read agent's marks, in the read's order.
    pub marks: Vec<Marks>,
    /// The agent whose Sign In ran reads signed in now: the line under the
    /// list and the rechecks on coming back stop.
    pub signed_in_now: bool,
    /// The waiting install's end, when one waited for this read.
    pub finish_install: Option<FinishInstall>,
}

/// The Agents step's rules (Swift `AgentsStepModel.show`, `finishInstall`,
/// `countsAsSignedIn`, `awaitsConfirmation`, `install`'s guard and
/// `OnboardingAgent.offersSignIn`).
pub fn agents(facts: &AgentsFacts) -> AgentsView {
    let listed: Vec<usize> = facts
        .agents
        .iter()
        .enumerate()
        .filter(|(_, agent)| agent.installed)
        .map(|(index, _)| index)
        .collect();
    let installable: Vec<usize> = facts
        .agents
        .iter()
        .enumerate()
        .filter(|(_, agent)| !agent.installed && install_page(&agent.id).is_some())
        .map(|(index, _)| index)
        .collect();
    let has = |set: &[String], id: &str| set.iter().any(|entry| entry == id);
    let marks = facts
        .agents
        .iter()
        .enumerate()
        .map(|(index, agent)| Marks {
            offers_sign_in: agent.installed && agent.auth != Auth::SignedIn,
            counts_as_signed_in: agent.auth == Auth::SignedIn
                || (agent.auth == Auth::Unknown && has(&facts.confirmed_logins, &agent.id)),
            awaits_confirmation: agent.auth == Auth::Unknown
                && has(&facts.logins_opened, &agent.id)
                && !has(&facts.confirmed_logins, &agent.id),
            can_install: installable.contains(&index) && !facts.installing,
        })
        .collect();
    let signed_in_now = facts.signing_in.as_deref().is_some_and(|id| {
        facts.agents.iter().any(|agent| agent.id == id && agent.auth == Auth::SignedIn)
    });
    let finish_install = facts.install_awaiting_read.as_deref().map(|id| {
        if listed.iter().any(|index| facts.agents.get(*index).is_some_and(|agent| agent.id == id)) {
            FinishInstall::SignIn
        } else {
            FinishInstall::Failed { message: INSTALLED_NOT_FOUND.to_owned() }
        }
    });
    AgentsView { listed, installable, marks, signed_in_now, finish_install }
}

#[cfg(test)]
#[path = "onboarding_steps_tests.rs"]
mod tests;
