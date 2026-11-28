//! The decisions of the app's agent, live, browser-history, terminal-comment, Chief and search
//! handlers (`CmuxNextApp/Handlers`), asked over the app FFI (`handlers_agentmisc_*` ops). The
//! app keeps the I/O (running `cmux live`, panels, sockets, reading `inspector.json`, views) and
//! the localized text: an answer names a refusal or message by its string key, never its words.
//!
//! - [`live_web`]: Edit cmux Live… / Stop Editing cmux Live: the `cmux live` argv, timeouts and
//!   which message a run ends with, or why it refuses.
//! - [`live_swift`]: Start / Stop Swift Live Mode: the refusal ladder (no CLI, not a tagged DEV
//!   build, no checkout, already on or off) and the detached argv.
//! - [`history_entry`]: Go Back or Forward to…: the typed offset to go to, or no entry.
//! - [`comment_target`]: Comment… on a terminal selection: whether the terminal can comment into
//!   its workspace chat, the root folder and the dialog's source title.
//! - [`chief_toggle`]: the Chief computer page toggle: close first, else which conversation opens.
//! - [`chief_endpoint_usable`]: whether a local Chief host's `inspector.json` may be used.
//! - [`search_text`]: the text Search All Windows matches a tab's title against.

use serde::{Deserialize, Serialize};

/// The bundle id prefix of a tagged DEV build (`com.cmuxterm.app.debug.<tag>`).
pub const TAGGED_BUNDLE_PREFIX: &str = "com.cmuxterm.app.debug.";

/// Seconds `cmux live start` may take: it may install the checkout's webviews packages first,
/// then waits up to 60 s for the server.
pub const LIVE_START_SECONDS: u64 = 300;
/// Seconds `cmux live stop` and the Swift Live Mode runs may take.
pub const LIVE_STOP_SECONDS: u64 = 30;
/// Seconds the Swift Live Mode starting / stopping toast shows.
pub const LIVE_SWIFT_TOAST_SECONDS: u64 = 20;

/// What Edit cmux Live… (`start`) or Stop Editing cmux Live (`stop`) knows.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LiveWebAsk {
    /// `start` or `stop`.
    pub action: String,
    /// The invocation's `path` (the checkout to load from); empty is none.
    pub path: Option<String>,
    /// The bundled `cmux` CLI is known.
    pub cli_known: bool,
    /// The registry is asking for a refusal (a menu or a socket asking), so no panel may open.
    pub capturing_refusal: bool,
    /// cmux Live is allowed (`WebDevOverride.isAllowed`): the app loads web-dev.json.
    pub live_allowed: bool,
}

/// What the app does for a [`LiveWebAsk`]: refuse with `refusal`, open the folder panel, or run
/// `argv` (toast `toast` for `toast_seconds`, then `done` once it finishes in `timeout_seconds`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LivePlan {
    /// A `LiveWebStrings` key (`liveWeb.noCLI`, `liveWeb.pathRequired`, `liveSwift.*`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refusal: Option<&'static str>,
    /// Open the choose-a-checkout folder panel; its pick runs the action again with the path.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub open_panel: bool,
    /// The bundled CLI's arguments.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub argv: Vec<String>,
    pub timeout_seconds: u64,
    pub toast_seconds: u64,
    /// The toast shown while it runs (a `LiveWebStrings` key; `liveWeb.starting` takes the path).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub toast: Option<&'static str>,
    /// The message once it finishes (`liveWeb.started` takes the path).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub done: Option<&'static str>,
}

impl LivePlan {
    fn refused(key: &'static str) -> Self {
        Self { refusal: Some(key), ..Self::default() }
    }
}

/// Edit cmux Live… / Stop Editing cmux Live. Unknown actions refuse as no CLI does.
pub fn live_web(ask: &LiveWebAsk) -> LivePlan {
    if !ask.cli_known {
        return LivePlan::refused("liveWeb.noCLI");
    }
    match ask.action.as_str() {
        "start" => match ask.path.as_deref().filter(|path| !path.is_empty()) {
            Some(path) => LivePlan {
                argv: ["live", "start", "--worktree", path].map(String::from).to_vec(),
                timeout_seconds: LIVE_START_SECONDS,
                toast_seconds: LIVE_START_SECONDS,
                toast: Some("liveWeb.starting"),
                // With cmux Live off the app ignores web-dev.json: the server runs, pages stay bundled.
                done: Some(if ask.live_allowed {
                    "liveWeb.started"
                } else {
                    "liveWeb.startedButOff"
                }),
                ..LivePlan::default()
            },
            None if ask.capturing_refusal => LivePlan::refused("liveWeb.pathRequired"),
            None => LivePlan { open_panel: true, ..LivePlan::default() },
        },
        "stop" => LivePlan {
            argv: ["live", "stop"].map(String::from).to_vec(),
            timeout_seconds: LIVE_STOP_SECONDS,
            toast_seconds: LIVE_STOP_SECONDS,
            toast: Some("liveWeb.stopping"),
            done: Some("liveWeb.stopped"),
            ..LivePlan::default()
        },
        _ => LivePlan::refused("liveWeb.noCLI"),
    }
}

/// What Start (`on`) or Stop Swift Live Mode knows.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LiveSwiftAsk {
    pub on: bool,
    pub cli_known: bool,
    /// The app's bundle id.
    pub bundle_id: Option<String>,
    /// `CMUXTERM_REPO_ROOT`; empty is none.
    pub repo_root: Option<String>,
    /// Swift Live Mode is on now.
    pub is_live: bool,
    /// The person's own Labs > Live Code write took, so the script skips its confirmation.
    pub setting_done: bool,
}

/// Start / Stop Swift Live Mode: why not (the menu's and the run's one ladder), else the
/// detached `cmux live start|stop --swift` run.
pub fn live_swift(ask: &LiveSwiftAsk) -> LivePlan {
    if !ask.cli_known {
        return LivePlan::refused("liveWeb.noCLI");
    }
    if !ask.bundle_id.as_deref().is_some_and(|id| id.starts_with(TAGGED_BUNDLE_PREFIX)) {
        return LivePlan::refused("liveSwift.notTagged");
    }
    let Some(tree) = ask.repo_root.as_deref().filter(|tree| !tree.is_empty()) else {
        return LivePlan::refused("liveSwift.noCheckout");
    };
    if ask.is_live == ask.on {
        return LivePlan::refused(if ask.on {
            "liveSwift.alreadyOn"
        } else {
            "liveSwift.alreadyOff"
        });
    }
    let verb = if ask.on { "start" } else { "stop" };
    let mut argv: Vec<String> =
        ["live", verb, "--swift", "--detach", "--worktree", tree].map(String::from).to_vec();
    if ask.setting_done {
        argv.push("--setting-done".into());
    }
    LivePlan {
        argv,
        timeout_seconds: LIVE_STOP_SECONDS,
        toast_seconds: LIVE_SWIFT_TOAST_SECONDS,
        toast: Some(if ask.on { "liveSwift.starting" } else { "liveSwift.stopping" }),
        done: Some(if ask.on { "liveSwift.started" } else { "liveSwift.stopped" }),
        ..LivePlan::default()
    }
}

/// What Go Back or Forward to… knows of the tab's back-forward list.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HistoryEntryAsk {
    /// The tab is a browser with a back-forward list.
    pub has_list: bool,
    /// The invocation's `entry`: the typed offset from the current page.
    pub entry: Option<String>,
    /// The current page's index in the list.
    pub current: i64,
    /// The list's length.
    pub count: i64,
    /// How many pages lie behind and ahead (the menus show only when one does).
    pub back: u64,
    pub forward: u64,
}

/// Go to `offset`, else refuse with `refusal` (`noBrowser`, `historyNoEntry`); `hidden` is why
/// the row is out of the menus and palette.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntryPlan {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub offset: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refusal: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hidden: Option<&'static str>,
}

/// The offset is typed text: zero, one that is not a number, or one whose addition overflows
/// (`i64::MAX` past a nonzero current) is no entry, not a trap.
pub fn history_entry(ask: &HistoryEntryAsk) -> HistoryEntryPlan {
    if !ask.has_list {
        return HistoryEntryPlan {
            refusal: Some("noBrowser"),
            hidden: Some("noBrowser"),
            offset: None,
        };
    }
    let hidden = (ask.back == 0 && ask.forward == 0).then_some("historyNoEntry");
    let offset =
        ask.entry.as_deref().and_then(swift_int).filter(|offset| *offset != 0).filter(|offset| {
            ask.current.checked_add(*offset).is_some_and(|index| (0..ask.count).contains(&index))
        });
    match offset {
        Some(offset) => HistoryEntryPlan { offset: Some(offset), refusal: None, hidden },
        None => HistoryEntryPlan { offset: None, refusal: Some("historyNoEntry"), hidden },
    }
}

/// Swift's `Int(String)`: an optional `+` or `-`, then ASCII digits only.
fn swift_int(text: &str) -> Option<i64> {
    let digits = text.strip_prefix(['+', '-']).unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// What Comment… on a terminal selection knows of the terminal and its workspace chat.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CommentTargetAsk {
    /// Labs `labs.commentThreads` is on.
    pub threads_on: bool,
    /// The invocation's tab kind (`pty`, `remoteTerminal`, …); none when it names no tab.
    pub kind: Option<String>,
    /// The workspace chat's agent session id; none when the workspace has no chat.
    pub session: Option<String>,
    /// The chat's git link keeps diff comment threads; none when the chat has no link.
    pub link_threads: Option<bool>,
    /// The chat tab's folder, else none.
    pub chat_folder: Option<String>,
    /// The terminal tab's working folder.
    pub cwd: Option<String>,
    /// The terminal's shown title.
    pub title: Option<String>,
}

/// Comment into the chat at `root`, the dialog's source titled `source` (none: the localized
/// Terminal), else why not: `placeholder` (the row's placeholder reason), `notATerminal`, `noChat`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommentTarget {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refusal: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

pub fn comment_target(ask: &CommentTargetAsk) -> CommentTarget {
    let refused = |key| CommentTarget { refusal: Some(key), ..CommentTarget::default() };
    if !ask.threads_on {
        return refused("placeholder");
    }
    if !matches!(ask.kind.as_deref(), Some("pty" | "remoteTerminal")) {
        return refused("notATerminal");
    }
    if ask.session.as_deref().is_none_or(str::is_empty) {
        return refused("noChat");
    }
    if ask.link_threads != Some(true) {
        return refused("placeholder");
    }
    let Some(root) =
        ask.chat_folder.clone().or_else(|| ask.cwd.clone()).filter(|root| root.starts_with('/'))
    else {
        return refused("noChat");
    };
    CommentTarget { refusal: None, root: Some(root), source: comment_source(ask.title.as_deref()) }
}

/// The dialog's source title: ChatQuote titles a source by its last path component and a
/// terminal title is not a path, so `/` becomes U+2215; an empty title is none (the localized Terminal).
pub fn comment_source(title: Option<&str>) -> Option<String> {
    title.filter(|title| !title.is_empty()).map(|title| title.replace('/', "\u{2215}"))
}

/// The Chief computer page toggle's ask.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChiefToggleAsk {
    /// The invocation's `open` (`1`: open even when shown).
    pub open: Option<String>,
    /// The invocation's `conversation`.
    pub conversation: Option<String>,
    /// The Chief Home's default conversation (the palette names none: the Chief Home shows first).
    pub default_conversation: Option<String>,
}

/// Try closing the shown pages first (`try_close`: a close that closes something is done), else
/// open `conversation`; none refuses (no window open).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChiefToggle {
    pub try_close: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub conversation: Option<String>,
}

pub fn chief_toggle(ask: &ChiefToggleAsk) -> ChiefToggle {
    ChiefToggle {
        try_close: ask.open.as_deref() != Some("1"),
        conversation: ask
            .conversation
            .clone()
            .or_else(|| ask.default_conversation.clone())
            .filter(|conversation| !conversation.is_empty()),
    }
}

/// A local Chief host's `inspector.json`, as the app read it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChiefEndpointAsk {
    /// The file's `url` host.
    pub host: Option<String>,
    /// The file names a host process.
    pub has_pid: bool,
    /// That process runs (`kill(pid, 0)` succeeded or refused with EPERM).
    pub pid_running: bool,
}

/// Whether the endpoint may be used: loopback only (its token is never sent elsewhere), and a
/// file whose host exited is stale (its port may belong to another program now).
pub fn chief_endpoint_usable(ask: &ChiefEndpointAsk) -> bool {
    ask.host.as_deref() == Some("127.0.0.1") && (!ask.has_pid || ask.pid_running)
}

/// A tab as Search All Windows matches its title.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SearchTextAsk {
    /// The strip's title for the tab (an agent chat by its chat).
    pub title: String,
    /// The tab's own shown title (a terminal's, which its shell set).
    pub display_title: String,
    pub kind: String,
    /// The tab runs an agent session.
    pub agent_session: bool,
    pub workspace_name: Option<String>,
    pub url: Option<String>,
}

/// The tab's shown title, its workspace's name and a browser's address, space-joined. Not a
/// terminal's folder (the shown title of one its shell has not titled): one folder word would
/// match every terminal opened there.
pub fn search_text(ask: &SearchTextAsk) -> String {
    let terminal = matches!(ask.kind.as_str(), "pty" | "remoteTerminal");
    let name = if !ask.agent_session && terminal { &ask.display_title } else { &ask.title };
    let url = if ask.kind == "browser" { ask.url.as_deref() } else { None };
    [Some(name.as_str()), ask.workspace_name.as_deref(), url]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" ")
}
