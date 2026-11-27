//! `cmux cloud start-session` and the composer's Cloud start, the app's
//! `CloudStartSession`, `CloudStartSessionAsks` and `CloudStartChat` rules moved
//! here (cmuxterm-hq `docs/rfd/drafts/why-swift.md`): the run's arguments
//! checked, the command that asks for it again, how a start's refusal reads,
//! the `--from-folder` checks before the disk is read, the run key, when a
//! machine this run made is deleted, the reply's code, and the per-chat ask
//! cards' state.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::machine_bootstrap::shell_quoted;

/// The longest `--agent`, in UTF-8 bytes.
pub const AGENT_MAX: usize = 64;
/// The longest `--cwd` or `--from-folder`, in UTF-8 bytes.
pub const PATH_MAX: usize = 4096;
/// How recent the machine list must be before `--name` takes or creates a machine (ms).
pub const LIST_FRESH_MS: u64 = 15_000;
/// How long a stopped machine has to start before the session (ms).
pub const CONNECT_WAIT_MS: u64 = 180_000;
/// How long an agent's ask card waits for the person (ms).
pub const ASK_WAIT_MS: u64 = 120_000;

/// Swift's `CharacterSet.whitespaces`: spaces and tabs, not line breaks.
fn is_space(c: char) -> bool {
    c.is_whitespace()
        && !matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

fn trimmed(text: Option<&str>) -> Option<String> {
    text.map(|text| text.trim_matches(is_space)).filter(|text| !text.is_empty()).map(str::to_owned)
}

/// The run's arguments as the invocation gave them.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Invocation {
    #[serde(default)]
    pub agent: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    /// The target's id when it names a machine.
    #[serde(default)]
    pub machine_id: Option<String>,
    /// `--from-folder` once checked (``from_folder``).
    #[serde(default)]
    pub from_folder: Option<String>,
    /// `--connection`: the local model connection this launch uses, independent of the account scope.
    #[serde(default)]
    pub connection: Option<String>,
}

/// A checked run.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    #[serde(default)]
    pub machine_id: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    pub agent: String,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub from_folder: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub connection: Option<String>,
}

/// Why a run's arguments are refused.
#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Invalid {
    AgentInvalid,
    CwdInvalid,
    ConnectionInvalid,
}

/// Whether `id` can name a connection (an `_acpmux/connections` id), as `CloudSetup.isConnectionID` reads it.
fn connection_ok(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_' | b':' | b'@'))
}

fn agent_ok(agent: &str) -> bool {
    !agent.is_empty()
        && agent.len() <= AGENT_MAX
        && agent
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '_' | '-'))
        && agent.chars().next().is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
}

/// The run's arguments, checked: `--agent` is a harness id, `--cwd` an absolute folder.
pub fn request(invocation: &Invocation) -> Result<Request, Invalid> {
    let agent =
        invocation.agent.as_deref().map(|agent| agent.trim_matches(is_space)).unwrap_or_default();
    if !agent_ok(agent) {
        return Err(Invalid::AgentInvalid);
    }
    let cwd = trimmed(invocation.cwd.as_deref());
    if let Some(cwd) = &cwd
        && (!cwd.starts_with('/') || cwd.len() > PATH_MAX || cwd.chars().any(char::is_control))
    {
        return Err(Invalid::CwdInvalid);
    }
    let connection = trimmed(invocation.connection.as_deref());
    if connection.as_deref().is_some_and(|id| !connection_ok(id)) {
        return Err(Invalid::ConnectionInvalid);
    }
    Ok(Request {
        machine_id: invocation.machine_id.clone(),
        name: trimmed(invocation.name.as_deref()),
        agent: agent.to_owned(),
        cwd,
        from_folder: invocation.from_folder.clone(),
        model: trimmed(invocation.model.as_deref()),
        connection,
    })
}

/// The command that asks for `request` again, every word as the shell reads it back.
pub fn command(request: &Request) -> String {
    let mut words = vec!["cmux cloud start-session".to_owned()];
    match &request.machine_id {
        Some(id) => words.push(format!("--target machine:{}", shell_quoted(id))),
        None => words
            .push(format!("--name {}", shell_quoted(request.name.as_deref().unwrap_or_default()))),
    }
    let model = request
        .model
        .as_deref()
        .map(|model| format!(" --model {}", shell_quoted(model)))
        .unwrap_or_default();
    words.push(format!("--agent {}{model}", request.agent));
    if let Some(cwd) = &request.cwd {
        words.push(format!("--cwd {}", shell_quoted(cwd)));
    }
    if let Some(folder) = &request.from_folder {
        words.push(format!("--from-folder {}", shell_quoted(folder)));
    }
    if let Some(connection) = &request.connection {
        words.push(format!("--connection {}", shell_quoted(connection)));
    }
    words.join(" ")
}

/// The codes that say the machine has no folder for the session.
/// Besides the app's own (`AgentRemoteStartRefusal.folderNeededCode`, `app.folder_needed`).
pub const FOLDER_NEEDED_CODES: [&str; 2] =
    ["agent_session.home_unconfirmed", "agent_session.above_home"];

/// How a start's refusal reads: the machine is up, its agent is not.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum StartFailure {
    /// The session needs a folder on the machine.
    NeedsFolder,
    /// A refusal with its own sentence (`code`).
    Named { code: String },
    /// The agent failed, for `reason`.
    AgentFailed { reason: String },
}

/// A refusal's text as a reason inside a sentence: trimmed, its trailing periods dropped.
pub fn reason(text: &str) -> String {
    text.trim().trim_end_matches('.').to_owned()
}

/// `code` is the start refusal's code, if the error was one; `named` the codes with
/// their own sentence; `folder_needed` the app's folder code (`AgentRemoteStartRefusal.folderNeededCode`).
pub fn start_failure(
    code: Option<&str>,
    message: &str,
    folder_needed: &str,
    named: &[String],
) -> StartFailure {
    match code {
        Some(code) if code == folder_needed || FOLDER_NEEDED_CODES.contains(&code) => {
            StartFailure::NeedsFolder
        }
        Some(code) if named.iter().any(|named| named == code) => {
            StartFailure::Named { code: code.to_owned() }
        }
        _ => StartFailure::AgentFailed { reason: reason(message) },
    }
}

/// Whether a failure past the machine deletes it: a machine this run `made`, a failure that
/// `strands` the start, and the account that asked still signed in.
pub fn releases(made: bool, strands: bool, same_account: bool) -> bool {
    made && strands && same_account
}

/// `--from-folder`'s checks before the disk is read.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FromFolder {
    /// None given (or only whitespace).
    None,
    /// Given beside `--cwd`.
    WithCwd,
    /// Too long or with control characters.
    Invalid,
    /// Read `path` on the disk (realpath and its refusal); the run's folder is `folder`.
    Check { path: String, folder: String },
}

pub fn from_folder(text: Option<&str>, has_cwd: bool) -> FromFolder {
    let Some(text) = text.filter(|text| !text.chars().all(char::is_whitespace)) else {
        return FromFolder::None;
    };
    if has_cwd {
        return FromFolder::WithCwd;
    }
    if text.len() > PATH_MAX || text.chars().any(char::is_control) {
        return FromFolder::Invalid;
    }
    let folder = match text.strip_suffix('/') {
        Some(trimmed) if text.chars().count() > 1 => trimmed,
        _ => text,
    };
    FromFolder::Check { path: text.to_owned(), folder: folder.to_owned() }
}

/// The machine half of a start's run key: its id, else its name.
pub fn run_key_machine(id: Option<&str>, name: Option<&str>) -> String {
    match id {
        Some(id) => format!("id:{id}"),
        None => format!("name:{}", name.unwrap_or_default()),
    }
}

/// What a failed composer start answers.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ReplyInput {
    /// The failure offers an upgrade (``crate::create_flow::pro_offer``).
    #[serde(default)]
    pub plan: bool,
    /// A move failure's own code.
    #[serde(default)]
    pub code: Option<String>,
    /// The failure was a move failure (else retry and send_again are ignored).
    #[serde(default)]
    pub move_failure: bool,
    #[serde(default)]
    pub retry: bool,
    #[serde(default)]
    pub send_again: bool,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct Reply {
    pub code: String,
    pub retryable: bool,
}

pub const PLAN_REQUIRED_REPLY: &str = "cloud_plan_required";
pub const START_FAILED_REPLY: &str = "cloud_start_failed";

/// The code and Retry of a failed start's reply.
pub fn reply(input: &ReplyInput) -> Reply {
    let code = if input.plan {
        PLAN_REQUIRED_REPLY.to_owned()
    } else {
        input
            .code
            .clone()
            .filter(|_| input.move_failure)
            .unwrap_or_else(|| START_FAILED_REPLY.to_owned())
    };
    Reply { code, retryable: input.move_failure && (input.retry || input.send_again) }
}

/// The card id of `tab`'s start ask.
pub fn card_id(tab: &str) -> String {
    format!("cloud-start-session-{tab}")
}

/// The dialog id of the ask `token` (a UUID, lowercased here).
pub fn dialog_id(token: &str) -> String {
    format!("cloud-start-{}", token.to_lowercase())
}

/// How the person answered an ask.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Answer {
    Start,
    NotNow,
    Expired,
    AccountChanged,
}

/// One chat's open ask.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct OpenAsk {
    pub token: String,
    pub dialog: String,
    /// Its run still waits for an answer.
    #[serde(default)]
    pub waiting: bool,
    #[serde(default)]
    pub answered: bool,
    #[serde(default)]
    pub ended: bool,
}

/// Every chat's start asks: the open ones, and the chats showing a done card.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Asks {
    #[serde(default)]
    pub open: BTreeMap<String, OpenAsk>,
    #[serde(default)]
    pub linked: BTreeSet<String>,
}

/// What `end_all` does per chat.
#[derive(Clone, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct EndAll {
    /// Done cards to clear.
    pub clear: Vec<String>,
    /// Waiting asks to answer `account_changed`.
    pub account_changed: Vec<String>,
    /// Asks past their answer to fail with `account_changed_while_starting`.
    pub fail: Vec<String>,
}

impl Asks {
    /// Opens `tab`'s ask `token`; `None` when one is open there already.
    pub fn begin(&mut self, tab: &str, token: &str) -> Option<String> {
        if self.open.contains_key(tab) {
            return None;
        }
        let dialog = dialog_id(token);
        self.open.insert(
            tab.to_owned(),
            OpenAsk {
                token: token.to_owned(),
                dialog: dialog.clone(),
                waiting: true,
                answered: false,
                ended: false,
            },
        );
        self.linked.remove(tab);
        Some(dialog)
    }

    /// The tab of the open ask `dialog`.
    pub fn tab_of(&self, dialog: &str) -> Option<String> {
        self.open.iter().find(|(_, ask)| ask.dialog == dialog).map(|(tab, _)| tab.clone())
    }

    /// Takes an answer for `tab`'s ask `dialog` once: whether it was taken.
    pub fn deliver(&mut self, tab: &str, dialog: &str) -> bool {
        match self.open.get_mut(tab) {
            Some(ask) if ask.dialog == dialog && !ask.answered && ask.waiting => {
                ask.answered = true;
                true
            }
            _ => false,
        }
    }

    /// The asks still waiting for the person, by chat.
    pub fn waiting(&self) -> Vec<(String, String)> {
        self.open
            .iter()
            .filter(|(_, ask)| ask.waiting && !ask.answered)
            .map(|(tab, ask)| (tab.clone(), ask.dialog.clone()))
            .collect()
    }

    /// The run's answer once it read `answer`: a Start whose ask was replaced or ended,
    /// or whose account changed, is `account_changed`. The ask stops waiting.
    pub fn settle(&mut self, tab: &str, token: &str, answer: Answer, same_account: bool) -> Answer {
        let current = self.open.get(tab).filter(|ask| ask.token == token);
        let answer = match answer {
            Answer::Start if current.is_none_or(|ask| ask.ended) || !same_account => {
                Answer::AccountChanged
            }
            answer => answer,
        };
        if let Some(ask) = self.open.get_mut(tab).filter(|ask| ask.token == token) {
            ask.waiting = false;
        }
        answer
    }

    /// Closes `tab`'s ask `token`: whether it was that chat's.
    pub fn finish(&mut self, tab: &str, token: &str) -> bool {
        if self.open.get(tab).is_none_or(|ask| ask.token != token) {
            return false;
        }
        self.open.remove(tab);
        true
    }

    /// `tab`'s ask `token` started its chat: the done card links it.
    pub fn started(&mut self, tab: &str, token: &str) -> bool {
        if !self.finish(tab, token) {
            return false;
        }
        self.linked.insert(tab.to_owned());
        true
    }

    /// A done card's button: the card is the chat's only while no later ask owns it.
    pub fn done_card_answered(&mut self, tab: &str) -> bool {
        if self.open.contains_key(tab) {
            return false;
        }
        self.linked.remove(tab);
        true
    }

    /// The account ended: done cards go, waiting asks hear `account_changed`, the rest fail.
    pub fn end_all(&mut self) -> EndAll {
        let mut end = EndAll {
            clear: self
                .linked
                .iter()
                .filter(|tab| !self.open.contains_key(*tab))
                .cloned()
                .collect(),
            ..EndAll::default()
        };
        self.linked.clear();
        self.open.retain(|tab, ask| {
            if ask.waiting {
                ask.ended = true;
                end.account_changed.push(tab.clone());
            } else {
                end.fail.push(tab.clone());
            }
            ask.waiting
        });
        end
    }
}

#[cfg(test)]
mod tests;
