//! What closing tabs asks first and whether it earns an undo toast.
//!
//! A closed terminal ends after the daemon's reap grace, so a person's close
//! asks only while a closing terminal is doing work (#17501, as classic
//! #17430): an agent at work in it (`app.warnBeforeClosingAgentSession`), else
//! a foreground program (`app.warnBeforeClosingTab`). The app asks the daemon
//! what each terminal [`reads`] names runs, then asks [`warning`] for the
//! question. Cmd-Shift-T reopens every close, so the undo toast is only for a
//! close that is costly to get back ([`toast`]; Lawrence 2026-10-12: "this
//! toast shows up too often").

use serde::{Deserialize, Serialize};

/// The New Tab page's addresses (WebKit's blank page, Chromium's New Tab page).
const NEW_TAB_PAGES: [&str; 3] = ["about:blank", "chrome://newtab/", "chrome://newtab"];

/// What a tab is, as its close reads it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TabKind {
    /// A terminal.
    Pty,
    Browser,
    /// Any other tab (a chat, a file, a diff).
    #[default]
    #[serde(other)]
    Other,
}

/// The facts of one closing tab.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ClosingTab {
    pub kind: TabKind,
    pub dead: bool,
    /// An internal page (Settings, History, What's New, an app's page).
    pub page: bool,
    /// A new chat still on its New Tab page.
    pub new_tab_page: bool,
    /// A browser tab's address.
    pub url: Option<String>,
    /// A new chat's typed text from before it has a session.
    pub unsent_draft: bool,
    /// The agent in the tab is working or waiting on a permission answer.
    pub agent_at_work: bool,
    /// That agent's name (`claude`), when it has one.
    pub agent: Option<String>,
    /// The status map says the tab works or waits on the person.
    pub status_working: bool,
}

impl ClosingTab {
    fn is_live_terminal(&self) -> bool {
        self.kind == TabKind::Pty && !self.dead
    }
}

/// Whether `url` is the New Tab page or the blank page.
pub fn is_new_tab_page(url: &str) -> bool {
    let url = url.to_lowercase();
    NEW_TAB_PAGES.contains(&url.as_str())
}

/// A tab that reopens with nothing lost: a page, a New Tab or blank page, a
/// dead tab. A new chat with typed text is not (its tab is still a New Tab page).
pub fn reopens_free(tab: &ClosingTab) -> bool {
    if tab.unsent_draft {
        return false;
    }
    if tab.dead || tab.page || tab.new_tab_page {
        return true;
    }
    if tab.kind != TabKind::Browser {
        return false;
    }
    let url = tab.url.as_deref().unwrap_or("");
    url.is_empty() || is_new_tab_page(url)
}

/// Whether a close earns the undo toast.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "decision")]
pub enum Toast {
    Show,
    Skip,
    /// Shows only if one of these live terminals (indices into the closing
    /// tabs) runs a program.
    AskTerminals {
        terminals: Vec<usize>,
    },
}

/// The toast decision for closing `tabs` together: several real tabs in one
/// gesture, an agent at work, or a new chat's unsent text show it; a
/// terminal shows it only if it runs a program; one idle tab and tabs that
/// reopen free never do.
pub fn toast(tabs: &[ClosingTab]) -> Toast {
    let real: Vec<(usize, &ClosingTab)> =
        tabs.iter().enumerate().filter(|(_, tab)| !reopens_free(tab)).collect();
    if real.len() >= 2 {
        return Toast::Show;
    }
    let working = |tab: &ClosingTab| tab.agent_at_work || tab.status_working || tab.unsent_draft;
    if real.iter().any(|(_, tab)| working(tab)) {
        return Toast::Show;
    }
    let terminals: Vec<usize> = real
        .into_iter()
        .filter(|(_, tab)| tab.kind == TabKind::Pty)
        .map(|(index, _)| index)
        .collect();
    if terminals.is_empty() { Toast::Skip } else { Toast::AskTerminals { terminals } }
}

/// The close warning settings. Both are required on the wire: the app's
/// fallback when settings are not loaded is on, so a missing field is a bug,
/// never "off".
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Warnings {
    /// `app.warnBeforeClosingTab`.
    pub warn_tab: bool,
    /// `app.warnBeforeClosingAgentSession`.
    pub warn_agent: bool,
}

/// What a close must read before it knows its question.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Reads {
    /// The working agents of the closing live terminals, as the question names
    /// them (nil: an unnamed agent, "The agent").
    pub agents: Vec<Option<String>>,
    /// The closing live terminals with no working agent (indices into the
    /// closing tabs): the daemon is asked what each runs, when `warn_tab`.
    pub others: Vec<usize>,
}

/// What closing `tabs` reads, or None when it can never ask (no live
/// terminal, or both warnings off). A terminal with a working agent is that
/// agent's question, never the program one.
pub fn reads(tabs: &[ClosingTab], warnings: Warnings) -> Option<Reads> {
    if !(warnings.warn_tab || warnings.warn_agent) || !tabs.iter().any(ClosingTab::is_live_terminal)
    {
        return None;
    }
    let mut agents = Vec::new();
    let mut others = Vec::new();
    for (index, tab) in tabs.iter().enumerate().filter(|(_, tab)| tab.is_live_terminal()) {
        if tab.agent_at_work {
            agents.push(display_name(tab.agent.as_deref()));
        } else if warnings.warn_tab {
            // Only the program warning reads what a terminal runs.
            others.push(index);
        }
    }
    Some(Reads { agents, others })
}

/// An agent's name as a question shows it: "claude" reads "Claude"; an
/// unnamed agent is None (the app says "The agent").
pub fn display_name(agent: Option<&str>) -> Option<String> {
    let mut chars = agent?.chars();
    let first = chars.next()?;
    Some(first.to_uppercase().chain(chars).collect())
}

/// What the daemon said one asked terminal runs.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TerminalAnswer {
    /// The tab's title, named when the terminal gave no answer.
    pub title: String,
    /// False: no answer in time (the daemon is slow or not connected), which
    /// never confirms that no program runs.
    pub answered: bool,
    /// The foreground program; None for the shell only.
    pub program: Option<String>,
}

/// The one question a close of live terminals asks.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Warning {
    /// The agent working in a closing terminal (the first, if several); None
    /// for an unnamed agent.
    Agent { name: Option<String> },
    /// Foreground programs in the closing terminals, unique and sorted, and
    /// the titles of the closing terminals that gave no answer (a tab title
    /// is not a program: the question names them apart).
    Programs { programs: Vec<String>, unanswered: Vec<String> },
}

/// The question for a close, or None to close at once. `agents` is
/// [`Reads::agents`]; `answers` what the terminals of [`Reads::others`] said.
/// With `unanswered_asks` (a person's close), a terminal that gave no answer
/// asks by its title: only a confirmed "no program" closes without the
/// question (lead, #31875).
pub fn warning(
    agents: &[Option<String>],
    answers: &[TerminalAnswer],
    unanswered_asks: bool,
    warnings: Warnings,
) -> Option<Warning> {
    if warnings.warn_agent
        && let Some(name) = agents.first()
    {
        return Some(Warning::Agent { name: name.clone() });
    }
    let mut programs: Vec<String> =
        answers.iter().filter(|a| a.answered).filter_map(|a| a.program.clone()).collect();
    programs.sort();
    programs.dedup();
    let unanswered: Vec<String> = if unanswered_asks {
        answers.iter().filter(|a| !a.answered).map(|a| a.title.clone()).collect()
    } else {
        Vec::new()
    };
    if warnings.warn_tab && (!programs.is_empty() || !unanswered.is_empty()) {
        return Some(Warning::Programs { programs, unanswered });
    }
    None
}

#[cfg(test)]
#[path = "close_tests.rs"]
mod tests;
