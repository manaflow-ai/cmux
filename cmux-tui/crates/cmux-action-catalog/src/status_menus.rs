//! The rows of the menu bar menu (the status item) and of the sidebar's profile menu, in the
//! app's language. The app sends what the menu shows besides its fixed rows (`MenuBarMenuState`)
//! and the actions its build binds, and builds the `NSMenu` from the rows
//! (`MenuBarMenuBuilder`, `ProfileMenuBuilder`); it asks through [`crate::ffi`]
//! (`menu_bar_items`, `menu_bar_action_ids`, `profile_menu`).
//!
//! The menu bar menu, top to bottom (user 2026-10-27, after Raycast's menu; user 2026-11-06: "for
//! our computer use i imagine w'll also want to maybe have something similar to this in our top
//! right menu button situation"): Computer Use, the Unread and Running chats, the account, the
//! agents that work or wait, opening cmux, help, cmux's community, the app, logs, then Sign Out
//! and Quit. Every fixed row runs a registry action; a row whose action the build does not bind is
//! left out, and so is a section left with no row, with one separator between two sections.
//!
//! A row as JSON, one key per row: `{"info":{"text","symbol"?,"avatar"}}`,
//! `{"action":{"id","title"?,"symbol"}}`, `{"setting":{"text","key","symbol"}}`,
//! `{"separator":true}`, `{"header":"text"}`, `{"chat":{"id","title","harness"?}}`,
//! `{"command":{"command":"openChat"|"computerUseResume"|"computerUseShowCursor"|"computerUseFloatingPreview","target","title","symbol"}}`
//! (`computerUseFloatingPreview`'s target is `"true"` to show the panel, `"false"` to hide it),
//! `{"sessionAction":{"id","session","title","symbol"}}`,
//! `{"computerUse":{"app"?,"bundleID"?,"items":[row…]}}`.

use serde_json::{Map, Value, json};

use crate::strings::lookup;

/// The table the menus' own titles are in (`ProfileActions.xcstrings`).
const TABLE: &str = "ProfileActions";

/// The most Computer Use sessions the row's submenu names.
pub const COMPUTER_USE_SESSION_LIMIT: usize = 5;

/// The most chats one list shows; the rest are behind More….
pub const CHAT_LIMIT: usize = 8;

/// Every action a menu bar row can run, so the app asks its registry about these alone.
pub const MENU_BAR_ACTION_IDS: &[&str] = &[
    "openTeamPicker",
    "palette.auth.signIn",
    "palette.auth.signOut",
    "agent.jumpToNextNeedingInput",
    "showMainWindow",
    "newTab",
    "home.show",
    "home.messageChiefPet",
    "palette.quickAgentChat",
    "sendFeedback",
    "help.documentation",
    "help.troubleshooting",
    "help.discord",
    "help.followOnX",
    "help.github",
    "updates.whatsNew",
    "about",
    "palette.applyUpdateIfAvailable",
    "palette.checkForUpdates",
    "openSettings",
    "help.revealLogs",
    "help.copyLogs",
    "quit",
    "search.chats",
    "agentActivity.open",
    "palette.computerUse.setup",
    "computerUseFocusCallingTerminal",
    "computerUseStop",
    "computerUseFocus",
];

/// The menus' text in one language.
pub struct Strings {
    locale: usize,
}

impl Strings {
    pub fn new(locale: &str) -> Self {
        Strings { locale: crate::strings::locale_index(locale) }
    }

    fn format(&self, key: &str, en: &str) -> String {
        if self.locale == 0 {
            return en.to_owned();
        }
        lookup(TABLE, key, self.locale).unwrap_or(en).to_owned()
    }

    /// `key`'s text with `args` in its `%@`/`%lld` (in order) or `%1$@`, `%2$@` (by position).
    fn filled(&self, key: &str, en: &str, args: &[&str]) -> String {
        let mut text = self.format(key, en);
        for (position, arg) in args.iter().enumerate() {
            let n = position + 1;
            let positional = [format!("%{n}$@"), format!("%{n}$lld")];
            if let Some(token) = positional.iter().find(|token| text.contains(token.as_str())) {
                text = text.replacen(token.as_str(), arg, 1);
            } else if let Some(token) = ["%@", "%lld"].iter().find(|token| text.contains(*token)) {
                text = text.replacen(token, arg, 1);
            }
        }
        text
    }
}

// MARK: - Rows

fn action(id: &str, title: Option<String>, symbol: &str) -> Value {
    let mut row = Map::new();
    row.insert("id".into(), json!(id));
    if let Some(title) = title {
        row.insert("title".into(), json!(title));
    }
    row.insert("symbol".into(), json!(symbol));
    json!({ "action": row })
}

fn info(text: String, symbol: Option<&str>, avatar: bool) -> Value {
    let mut row = Map::new();
    row.insert("text".into(), json!(text));
    if let Some(symbol) = symbol {
        row.insert("symbol".into(), json!(symbol));
    }
    row.insert("avatar".into(), json!(avatar));
    json!({ "info": row })
}

fn separator() -> Value {
    json!({ "separator": true })
}

fn command(name: &str, target: &str, title: String, symbol: &str) -> Value {
    json!({ "command": { "command": name, "target": target, "title": title, "symbol": symbol } })
}

fn session_action(id: &str, session: &str, title: String, symbol: &str) -> Value {
    json!({ "sessionAction": { "id": id, "session": session, "title": title, "symbol": symbol } })
}

fn str_field<'a>(object: &'a Value, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

fn int_field(object: &Value, key: &str) -> i64 {
    object.get(key).and_then(Value::as_i64).unwrap_or(0)
}

fn bool_field(object: &Value, key: &str) -> bool {
    object.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn present(value: Option<&Value>) -> Option<&Value> {
    value.filter(|value| !value.is_null())
}

/// The menu bar menu's rows for `state` (the module doc's `MenuBarMenuState` as JSON), with
/// the rows whose action `is_bound` refuses and the empty sections left out, never starting or
/// ending with a separator.
pub fn menu_bar_items(
    state: &Value,
    strings: &Strings,
    is_bound: &dyn Fn(&str) -> bool,
) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    for section in sections(state, strings) {
        let rows = bound(section, is_bound);
        if !rows.iter().any(|row| row.get("header").is_none()) {
            continue;
        }
        if !out.is_empty() {
            out.push(separator());
        }
        out.extend(rows);
    }
    out
}

/// `rows` without unbound actions, in submenus too, and without a separator left at an end or
/// next to another.
fn bound(rows: Vec<Value>, is_bound: &dyn Fn(&str) -> bool) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    for mut row in rows {
        let id =
            row.get("action").or_else(|| row.get("sessionAction")).and_then(|r| str_field(r, "id"));
        if id.is_some_and(|id| !is_bound(id)) {
            continue;
        }
        if row.get("setting").is_some() && !is_bound("openSettings") {
            continue;
        }
        if row.get("separator").is_some()
            && out.last().is_none_or(|last| last.get("separator").is_some())
        {
            continue;
        }
        if let Some(items) = row.get_mut("computerUse").and_then(|cu| cu.get_mut("items")) {
            let inner = std::mem::take(items).as_array().cloned().unwrap_or_default();
            *items = Value::Array(bound(inner, is_bound));
        }
        out.push(row);
    }
    if out.last().is_some_and(|last| last.get("separator").is_some()) {
        out.pop();
    }
    out
}

fn sections(state: &Value, strings: &Strings) -> Vec<Vec<Value>> {
    let computer_use: Vec<Value> = present(state.get("computerUse"))
        .map(|cu| vec![computer_use(cu, strings)])
        .unwrap_or_default();
    let unread =
        chats(state.get("unread"), strings.format("menu.menuBar.unread", "Unread"), strings);
    let running =
        chats(state.get("running"), strings.format("menu.menuBar.running", "Running"), strings);
    let signed_in = present(state.get("account"));
    let mut account = Vec::new();
    if let Some(signed_in) = signed_in {
        let lines = signed_in.get("lines").and_then(Value::as_array).cloned().unwrap_or_default();
        for (index, line) in lines.iter().enumerate() {
            account.push(info(line.as_str().unwrap_or_default().to_owned(), None, index == 0));
        }
        if let Some(team) = str_field(signed_in, "team") {
            let symbol = str_field(signed_in, "teamSymbol").unwrap_or("person.2");
            account.push(action("openTeamPicker", Some(team.to_owned()), symbol));
        }
    } else {
        account.push(action(
            "palette.auth.signIn",
            Some(strings.format("menu.menuBar.signIn", "Sign In to cmux…")),
            "person.crop.circle",
        ));
    }
    let mut agents = Vec::new();
    if let Some(awake) = present(state.get("keepingAwake")) {
        // A click opens the setting behind the hold (user 2026-11-09, on the defaults: "nor sure").
        let title = strings.format("menu.menuBar.keepingAwake", "Keeping Mac awake");
        agents.push(match str_field(awake, "setting") {
            Some(key) => {
                json!({ "setting": { "text": title, "key": key, "symbol": "cup.and.saucer" } })
            }
            None => info(title, Some("cup.and.saucer"), false),
        });
        let commands = int_field(awake, "commands");
        if commands > 0 {
            let line = strings.filled(
                "menu.menuBar.commandsRunning",
                "Commands running: %lld",
                &[&commands.to_string()],
            );
            agents.push(info(line, Some("terminal"), false));
        }
    }
    let working = int_field(state, "agentsWorking");
    if working > 0 {
        let line = strings.filled(
            "menu.menuBar.agentsWorking",
            "Agents working: %lld",
            &[&working.to_string()],
        );
        agents.push(info(line, Some("circle.dotted"), false));
    }
    let waiting = int_field(state, "agentsNeedingInput");
    if waiting > 0 {
        let title =
            strings.filled("menu.menuBar.needsInput", "Needs input: %lld", &[&waiting.to_string()]);
        agents.push(action("agent.jumpToNextNeedingInput", Some(title), "exclamationmark.bubble"));
    }
    let open = vec![
        action(
            "showMainWindow",
            Some(strings.format("menu.menuBar.openCmux", "Open cmux")),
            "macwindow",
        ),
        action("newTab", None, "plus.rectangle.on.rectangle"),
        action("home.show", None, "house"),
        action("home.messageChiefPet", None, "bubble.left"),
        action("palette.quickAgentChat", None, "bubble.left.and.text.bubble.right"),
    ];
    let help = vec![
        action("sendFeedback", None, "envelope"),
        action("help.documentation", None, "book"),
        action("help.troubleshooting", None, "lifepreserver"),
    ];
    let community = vec![
        action("help.discord", None, "bubble.left.and.bubble.right"),
        action("help.followOnX", None, "at"),
        action("help.github", None, "chevron.left.forwardslash.chevron.right"),
        action("updates.whatsNew", None, "sparkles"),
    ];
    // Restart to Update only on a click (the nightly restart policy): the row runs the same
    // install path as the Update Ready card's button.
    let update = if bool_field(state, "updateReady") {
        action(
            "palette.applyUpdateIfAvailable",
            Some(strings.format("menu.menuBar.restartToUpdate", "Restart to Update")),
            "arrow.down.circle.fill",
        )
    } else {
        action("palette.checkForUpdates", None, "arrow.down.circle")
    };
    let app =
        vec![action("about", None, "info.circle"), update, action("openSettings", None, "gear")];
    let logs = vec![
        action("help.revealLogs", None, "folder"),
        action("help.copyLogs", None, "doc.on.clipboard"),
    ];
    let mut end = Vec::new();
    if signed_in.is_some() {
        end.push(action("palette.auth.signOut", None, "rectangle.portrait.and.arrow.right"));
    }
    end.push(action("quit", None, "power"));
    vec![computer_use, unread, running, account, agents, open, help, community, app, logs, end]
}

/// A chat list under its header, ending with More… (Search Everything) past the cap; empty for none.
fn chats(list: Option<&Value>, header: String, strings: &Strings) -> Vec<Value> {
    let Some(list) = present(list) else { return Vec::new() };
    let shown = list.get("shown").and_then(Value::as_array).cloned().unwrap_or_default();
    if shown.is_empty() {
        return Vec::new();
    }
    let mut rows = vec![json!({ "header": header })];
    rows.extend(shown.into_iter().map(|chat| json!({ "chat": chat })));
    if int_field(list, "more") > 0 {
        rows.push(action(
            "search.chats",
            Some(strings.format("menu.menuBar.more", "More…")),
            "ellipsis",
        ));
    }
    rows
}

/// The Computer Use row and its submenu (user 2026-11-09: "make a menu bar that lets you: stop on
/// agent's CU (must communicate to agent if stopped), focus on an agents cursor for CU"): per
/// agent session, its line (who, on which app; acting now, idle or stopped), then Stop (or Resume
/// once stopped), Show Cursor and Show Window; then Focus Calling Terminal, Stop for every agent,
/// and Agent Activity. With no session: Agent Activity and setup. There is no Take Over: the
/// person takes over by using the mouse or keyboard (`computerUse.pauseOnTakeover`).
fn computer_use(state: &Value, strings: &Strings) -> Value {
    let sessions = state.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
    let Some(newest) = sessions.first() else {
        let mut items = floating_preview_rows(state, strings);
        items.extend([
            action("agentActivity.open", None, "cursorarrow.click.2"),
            action("palette.computerUse.setup", None, "gear"),
        ]);
        return json!({ "computerUse": { "items": items } });
    };
    let mut items = Vec::new();
    for session in sessions.iter().take(COMPUTER_USE_SESSION_LIMIT) {
        items.extend(session_rows(session, strings));
        items.push(separator());
    }
    items.extend([
        action("computerUseFocusCallingTerminal", None, "terminal"),
        action(
            "computerUseStop",
            Some(strings.format("menu.menuBar.computerUse.stopAll", "Stop All Agents")),
            "stop.circle",
        ),
        separator(),
    ]);
    items.extend(floating_preview_rows(state, strings));
    items.push(action("agentActivity.open", None, "cursorarrow.click.2"));
    let mut row = Map::new();
    if let Some(app) = str_field(newest, "appName") {
        row.insert("app".into(), json!(app));
    }
    if let Some(bundle) = str_field(newest, "bundleID") {
        row.insert("bundleID".into(), json!(bundle));
    }
    row.insert("items".into(), Value::Array(items));
    json!({ "computerUse": row })
}

/// Show or Hide Floating Preview while `computerUse.floatingPreview` is on (`floatingPreview` in
/// the state; user 2026-11-22, paraphrased: show the running preview, drag it around, hide it); nothing
/// while it is off.
fn floating_preview_rows(state: &Value, strings: &Strings) -> Vec<Value> {
    match state.get("floatingPreview").and_then(Value::as_bool) {
        Some(true) => vec![command(
            "computerUseFloatingPreview",
            "false",
            strings
                .format("menu.menuBar.computerUse.floatingPreview.hide", "Hide Floating Preview"),
            "pip.remove",
        )],
        Some(false) => vec![command(
            "computerUseFloatingPreview",
            "true",
            strings
                .format("menu.menuBar.computerUse.floatingPreview.show", "Show Floating Preview"),
            "pip",
        )],
        None => Vec::new(),
    }
}
/// One session's line and its rows: Stop or Resume, Show Cursor, Show Window.
fn session_rows(session: &Value, strings: &Strings) -> Vec<Value> {
    let id = str_field(session, "id").unwrap_or_default();
    let stopped = bool_field(session, "stopped");
    let line = session_line(session, strings);
    let symbol = if stopped {
        "stop.circle"
    } else if bool_field(session, "acting") {
        "cursorarrow.motionlines"
    } else {
        "cursorarrow"
    };
    let title = if stopped {
        strings.filled("menu.menuBar.computerUse.stoppedLine", "%@ (Stopped)", &[&line])
    } else {
        line
    };
    let stop_or_resume = if stopped {
        command(
            "computerUseResume",
            id,
            strings.format("menu.menuBar.computerUse.resume", "Resume"),
            "play.circle",
        )
    } else {
        session_action(
            "computerUseStop",
            id,
            strings.format("menu.menuBar.computerUse.stop", "Stop"),
            "stop.circle",
        )
    };
    vec![
        info(title, Some(symbol), false),
        stop_or_resume,
        command(
            "computerUseShowCursor",
            id,
            strings.format("menu.menuBar.computerUse.showCursor", "Show Cursor"),
            "scope",
        ),
        session_action(
            "computerUseFocus",
            id,
            strings.format("menu.menuBar.computerUse.showWindow", "Show Window"),
            "macwindow",
        ),
    ]
}

/// "Claude Code in Notes", or the one of them the worker knows.
fn session_line(session: &Value, strings: &Strings) -> String {
    match (str_field(session, "agent"), str_field(session, "appName")) {
        (Some(agent), Some(app)) => {
            strings.filled("menu.menuBar.computerUse.agentInApp", "%1$@ in %2$@", &[agent, app])
        }
        (Some(agent), None) => agent.to_owned(),
        (None, Some(app)) => app.to_owned(),
        (None, None) => strings.format("menu.menuBar.computerUse.anAgent", "An agent"),
    }
}

/// The reply to `menu_bar_items`: `{"items":[row…]}` for `request`'s `state`, `locale` and
/// `bound` (the ids of [`MENU_BAR_ACTION_IDS`] the build binds).
pub fn menu_bar_reply(request: &Value) -> Value {
    let strings = Strings::new(str_field(request, "locale").unwrap_or(""));
    let bound: Vec<&str> = request
        .get("bound")
        .and_then(Value::as_array)
        .map(|ids| ids.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let state = request.get("state").cloned().unwrap_or(Value::Null);
    json!({ "items": menu_bar_items(&state, &strings, &|id| bound.contains(&id)) })
}

// MARK: - Profile menu

/// The setting the Show Chief Pet / Hide Chief Pet row flips (CmuxNextSettings `HomeChiefPetSetting`).
pub const CHIEF_PET_SETTING: &str = "home.chiefPetEnabled";

fn row(id: &str, title: Option<String>, symbol: &str) -> Value {
    let mut row = Map::new();
    row.insert("action".into(), json!(id));
    if let Some(title) = title {
        row.insert("title".into(), json!(title));
    }
    row.insert("symbol".into(), json!(symbol));
    Value::Object(row)
}

/// The sidebar profile menu (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2, Lawrence 2026-10-07), top
/// to bottom: the current profile's options, the submenus, Show Chief, Settings, Check for
/// Updates, the account rows (Accounts…, Cloud), then New Tab and Incognito Window. "New profile"
/// is hidden until the profiles lane exists. As JSON: `profileActions`, `submenus` (`key`,
/// `title`, `symbol`, `actions`), `chief`, `settings`, `updates`, `account`, `creation` (rows:
/// `action`, `title`?, `symbol`), `chiefPetSetting`, and the Show/Hide Chief Pet titles.
pub fn profile_menu(strings: &Strings) -> Value {
    let submenu = |key: &str, title_key: &str, en: &str, symbol: &str, actions: &[&str]| json!({ "key": key, "title": strings.format(title_key, en), "symbol": symbol, "actions": actions });
    json!({
        // The current profile's submenu: its own options (real switching and creating come with
        // the profiles lane).
        "profileActions": ["browserProfile.rename", "browserProfile.setColor", "browserProfile.setIcon", "browserProfile.manageExtensions"],
        "submenus": [
            submenu("bookmarks", "menu.profile.bookmarks", "Bookmarks", "bookmark",
                    &["bookmark.addPage", "bookmark.addAllTabs", "bookmark.toggleBar", "bookmark.manager", "bookmark.import"]),
            submenu("downloads", "menu.profile.downloads", "Downloads", "arrow.down.to.line", &["browser.downloads.showFolder"]),
            submenu("extensions", "menu.profile.extensions", "Extensions", "puzzlepiece",
                    &["browser.extensions.manage", "browser.extensions.webStore", "browser.extensions.loadUnpacked"]),
            submenu("history", "menu.profile.history", "History", "clock.arrow.circlepath",
                    &["history.show", "recentlyClosed", "history.reopen", "history.clear"]),
            submenu("developers", "menu.profile.developers", "Developers", "chevron.left.forwardslash.chevron.right",
                    &["toggleBrowserDeveloperTools", "showBrowserJavaScriptConsole", "inspectBrowserElement"]),
        ],
        // Show Chief (David Beyer, Nov 20): opens the Chief, its conversation or the side panel,
        // as the sidebar's Chief row does.
        "chief": row("home.openChief", Some(strings.format("menu.profile.showChief", "Show Chief")), "sparkles"),
        // Settings…, under Show Chief Pet: the one settings area (David Beyer 2026-11-20).
        "settings": row("openSettings", None, "gear"),
        // Check for Updates…, under Settings: the profile menu is the sidebar's app menu.
        "updates": row("palette.checkForUpdates", None, "arrow.down.circle"),
        // Under Settings: the signed-in accounts and cmux Cloud (PRIORITIES 1.14).
        "account": [
            row("accounts.show", None, "person.crop.circle"),
            row("palette.openCloudPane", Some(strings.format("menu.profile.cloud", "Cloud")), "cloud"),
        ],
        "creation": [
            row("newTab.default", None, "plus"),
            row("newIncognitoWindow", Some(strings.format("menu.profile.incognito", "Incognito Window")), "eyeglasses"),
        ],
        "chiefPetSetting": CHIEF_PET_SETTING,
        "showChiefPet": strings.format("menu.profile.showChiefPet", "Show Chief Pet"),
        "hideChiefPet": strings.format("menu.profile.hideChiefPet", "Hide Chief Pet"),
    })
}
