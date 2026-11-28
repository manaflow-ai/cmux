//! What a new workspace starts with (`WorkspaceSpawn`): its arguments from `newTab`'s invocation,
//! the folder it starts in, the name its row shows from the press, its first terminal's start, and
//! whether the store can show it before the daemon answers.
//!
//! Closures and the app's own objects (a chat seed, a browser tab, callbacks) stay in Swift; a
//! [`Spawn`] carries only whether each is there.

use crate::env::terminal_environment;
use crate::path::{expand_tilde, folder_name};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// The origin of a run the person made (`ActionInvocation.origin == .user`).
pub const USER_ORIGIN: &str = "user";

/// One workspace create's facts (`WorkspaceSpawn`), in the shape Swift's `Codable` gives it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Spawn {
    /// Its own folder.
    pub cwd: Option<String>,
    /// A key fixed by its caller (Import from Conductor); nil: a new key.
    pub key: Option<String>,
    /// The folder of the terminal or chat the person worked in.
    pub inherited_cwd: Option<String>,
    /// Its own name.
    pub name: Option<String>,
    /// The command its first terminal runs.
    pub command: Option<String>,
    /// The caller's extra environment.
    pub env: BTreeMap<String, String>,
    /// Keep the first terminal after its program exits.
    pub keep: bool,
    /// The room it is born in; nil: its window's.
    pub profile: Option<String>,
    /// A browser profile it uses by default.
    pub browser_profile: Option<String>,
    /// It names a sidebar slot of its own.
    pub has_slot: bool,
    /// It opens on the New Tab page.
    pub opens_new_tab_page: bool,
    /// It opens with a first chat (a seed).
    pub has_first_chat: bool,
    /// The session its first chat tab shows.
    pub first_session: Option<String>,
    /// The key hold of the press.
    pub input_token: Option<String>,
    /// Its only tab is a browser tab the create makes.
    pub has_first_browser: bool,
}

/// `newTab`'s arguments as the invocation carries them (`WorkspaceSpawn.init(_: ActionInvocation)`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct InvocationArgs {
    /// `cwd`'s string value.
    pub cwd: Option<String>,
    /// `name`'s string value.
    pub name: Option<String>,
    /// `command`'s string value.
    pub command: Option<String>,
    /// `keep`'s bool value.
    pub keep: Option<bool>,
    /// `profile` as a target: its id, kept as it is.
    pub profile_target: Option<String>,
    /// `profile` as a string.
    pub profile: Option<String>,
    /// `env`: a JSON object of strings, as text.
    pub env: Option<String>,
    /// The invocation's origin (`user`, `cli`, `script`, ...).
    pub origin: Option<String>,
    /// The person's home folder, for `~`.
    pub home: String,
    /// The process's folder, for a relative `cwd`'s name.
    pub base: Option<String>,
}

fn non_empty(value: Option<&str>) -> Option<String> {
    value.filter(|text| !text.is_empty()).map(str::to_owned)
}

/// The string values of a JSON object `text`; nil for text that is not one. Values that are not
/// strings are dropped (`compactMapValues { $0 as? String }`).
pub fn parse_env(text: &str) -> Option<BTreeMap<String, String>> {
    let value: serde_json::Value = serde_json::from_str(text).ok()?;
    let object = value.as_object()?;
    Some(
        object
            .iter()
            .filter_map(|(key, value)| value.as_str().map(|text| (key.clone(), text.to_owned())))
            .collect(),
    )
}

impl Spawn {
    /// A spawn opening `directory`, named after it (`WorkspaceSpawn.init(opening:)`).
    pub fn opening(directory: Option<&str>, base: Option<&str>) -> Spawn {
        Spawn {
            cwd: directory.map(str::to_owned),
            name: directory.and_then(|directory| folder_name(directory, base)),
            ..Spawn::default()
        }
    }

    /// The spawn of `newTab`'s invocation `args`: a non-empty `cwd` with `~` expanded, a non-empty
    /// `name` else the folder's name, a non-empty `command`, `keep`, the profile (a target's id, else
    /// a non-empty string), the `env` object's strings, and the New Tab page for the person's own run
    /// with no command.
    pub fn from_invocation(args: &InvocationArgs) -> Spawn {
        let cwd = non_empty(args.cwd.as_deref()).map(|cwd| expand_tilde(&cwd, &args.home));
        let name = non_empty(args.name.as_deref())
            .or_else(|| cwd.as_deref().and_then(|cwd| folder_name(cwd, args.base.as_deref())));
        let command = non_empty(args.command.as_deref());
        let profile = args.profile_target.clone().or_else(|| non_empty(args.profile.as_deref()));
        let env = args.env.as_deref().and_then(parse_env).unwrap_or_default();
        let opens_new_tab_page = args.origin.as_deref() == Some(USER_ORIGIN) && command.is_none();
        Spawn {
            cwd,
            name,
            command,
            keep: args.keep == Some(true),
            profile,
            env,
            opens_new_tab_page,
            ..Spawn::default()
        }
    }

    /// A plain Cmd-N: the New Tab page with nothing of its own (no key, chat, session, command,
    /// browser profile or folder), which may show the workspace reserved before the key.
    pub fn is_plain_new_tab_page(&self) -> bool {
        self.opens_new_tab_page
            && self.key.is_none()
            && !self.has_first_chat
            && self.first_session.is_none()
            && self.command.is_none()
            && self.browser_profile.is_none()
            && self.cwd.is_none()
    }

    /// The folder the workspace starts in: its own, else (on this Mac) its room's non-empty default
    /// with `~` expanded and then the folder it inherited, else the daemon's default.
    pub fn start_folder(
        &self,
        room_folder: Option<&str>,
        local: bool,
        daemon_default: Option<&str>,
        home: &str,
    ) -> Option<String> {
        if let Some(cwd) = &self.cwd {
            return Some(cwd.clone());
        }
        if local && let Some(room) = room_folder.filter(|folder| !folder.is_empty()) {
            return Some(expand_tilde(room, home));
        }
        if local && let Some(inherited) = &self.inherited_cwd {
            return Some(inherited.clone());
        }
        daemon_default.map(str::to_owned)
    }

    /// The name this create's row shows from the press: its own, else (only for a create into a
    /// window, which shows a row) the daemon's next default `next`; nil keeps the daemon's own
    /// numbering.
    pub fn row_name(&self, in_window: bool, next: impl FnOnce() -> String) -> Option<String> {
        self.name.clone().or_else(|| in_window.then(next))
    }

    /// Whether the store can show this create's workspace before the daemon answers: the New Tab
    /// page, a chat or a session, with no command and no browser profile, and a folder of its own
    /// only on this Mac.
    pub fn shows_before_daemon(&self, local: bool) -> bool {
        (self.opens_new_tab_page || self.has_first_chat || self.first_session.is_some())
            && self.command.is_none()
            && self.browser_profile.is_none()
            && (self.cwd.is_none() || local)
    }

    /// Whether this create opens on the New Tab page (or a first chat), not a terminal
    /// (`WorkspaceCreation.opensPage`): it asks for one, runs no command, and `tabs` can host it.
    pub fn opens_page(&self, tabs: &AgentTabFacts) -> bool {
        let chat = self.has_first_chat || self.first_session.is_some();
        (self.opens_new_tab_page || chat) && self.command.is_none() && tabs.opens_first_page(chat)
    }

    /// What its first terminal starts with (`WorkspaceSpawn.terminalStart`).
    pub fn terminal_start(&self, facts: &TerminalStartFacts) -> TerminalStart {
        let room = if facts.local { facts.room.as_ref() } else { None };
        let env = facts.sends_env.then(|| {
            terminal_environment(
                &facts.app,
                room.map(|room| &room.env),
                &self.env,
                &facts.workspace,
                &facts.terminal,
            )
        });
        let keep = (self.keep && facts.reaps).then_some(true);
        let cwd = self.start_folder(
            room.and_then(|room| room.cwd.as_deref()),
            facts.local,
            facts.daemon_default.as_deref(),
            &facts.home,
        );
        TerminalStart { env, keep, cwd }
    }
}

/// What the agent tab store knows of one daemon (`AgentTabStore.canHost`, `opensFirstPage`,
/// `showsWorkspaceAtOnce`, `holdsTabs`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AgentTabFacts {
    /// This app can host a chat at all.
    pub can_host_chat: bool,
    /// This Mac's acpmux host is known.
    pub has_local_host: bool,
    /// The daemon holds agent tabs (`agent-session-tabs-v1`).
    pub holds_tabs: bool,
    /// The daemon is this Mac's.
    pub daemon_is_local: bool,
}

impl AgentTabFacts {
    /// A chat tab can open on the daemon.
    pub fn can_host(&self) -> bool {
        self.can_host_chat && self.has_local_host && self.holds_tabs
    }

    /// The New Tab page (or with `chat`, a first chat) can open on the daemon: only this Mac's
    /// daemon hosts the page; a chat opens on any daemon that hosts tabs.
    pub fn opens_first_page(&self, chat: bool) -> bool {
        self.can_host() && (self.daemon_is_local || chat)
    }

    /// Cmd-N can show its workspace before the daemon answers: this Mac's daemon, which hosts the page.
    pub fn shows_workspace_at_once(&self) -> bool {
        self.daemon_is_local && self.has_local_host && self.can_host()
    }
}

/// A room's terminal defaults (`ProfileDefaults`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RoomDefaults {
    /// Its environment.
    pub env: BTreeMap<String, String>,
    /// Its start folder.
    pub cwd: Option<String>,
}

/// The facts a first terminal's start reads (`terminalStart`'s arguments).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TerminalStartFacts {
    /// This Mac's launch identity (empty on a Cloud machine).
    pub app: BTreeMap<String, String>,
    /// The room's defaults.
    pub room: Option<RoomDefaults>,
    /// The daemon is this Mac's.
    pub local: bool,
    /// The daemon's default folder.
    pub daemon_default: Option<String>,
    /// The workspace key.
    pub workspace: String,
    /// The terminal id the app reserved.
    pub terminal: String,
    /// The daemon takes an environment (`terminal-env-v1`).
    pub sends_env: bool,
    /// The daemon reaps terminals (`terminal-reap-v1`).
    pub reaps: bool,
    /// The person's home folder, for `~`.
    pub home: String,
}

/// What a new workspace's first terminal starts with (`TerminalStart`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalStart {
    /// Its environment; nil for a daemon that takes none.
    pub env: Option<BTreeMap<String, String>>,
    /// True keeps it after its program exits; nil leaves the daemon's default.
    pub keep: Option<bool>,
    /// The folder it starts in.
    pub cwd: Option<String>,
}
