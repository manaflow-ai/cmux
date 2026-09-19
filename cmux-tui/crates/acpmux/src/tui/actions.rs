//! Every user-facing action in one table, like cmux-tui's action registry.
//! The table feeds the command palette, `/name` commands, and the help
//! dialog, so a new action is added in one place. Key chords in `keys.rs`
//! and mouse buttons call `run_action` too, so the palette never disagrees
//! with what a key does.

use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Palette,
    Help,
    Quit,
    NewDraft,
    NewForm,
    NextSession,
    PrevSession,
    FocusSidebar,
    FocusContent,
    FocusTranscript,
    FocusComposer,
    ToggleSidebar,
    SidebarNarrow,
    SidebarWiden,
    Send,
    Steer,
    Cancel,
    Stop,
    Delete,
    Rename,
    Fork,
    Model,
    Mode,
    Policy,
    Effort,
    Directory,
    Agent,
    Set,
    ToggleThoughts,
    ToggleSystem,
    Allow,
    Deny,
    ScrollTop,
    ScrollBottom,
    PageUp,
    PageDown,
    Web,
    AddHost,
    RemoveHost,
    Export,
    Import,
    Undo,
}

pub struct ActionDef {
    pub action: Action,
    /// Slash-command name, also the palette id.
    pub name: &'static str,
    pub aliases: &'static [&'static str],
    pub label: &'static str,
    /// Key chord shown in the palette and help; empty when none.
    pub keys: &'static str,
    pub group: &'static str,
    /// Argument hint. When set and the palette picks the action without
    /// arguments, the command line opens with `/name ` for completion.
    pub args: &'static str,
}

pub const ACTIONS: &[ActionDef] = &[
    ActionDef { action: Action::Palette, name: "palette", aliases: &["commands"], label: "command palette", keys: "/  Ctrl-Shift-p  Cmd-k", group: "general", args: "" },
    ActionDef { action: Action::Help, name: "help", aliases: &["keys"], label: "all keys", keys: "?", group: "general", args: "" },
    ActionDef { action: Action::Web, name: "web", aliases: &[], label: "open the web dashboard", keys: "", group: "general", args: "" },
    ActionDef { action: Action::Quit, name: "quit", aliases: &["q", "detach"], label: "leave; every agent keeps running", keys: "Ctrl-q", group: "general", args: "" },
    ActionDef { action: Action::NewDraft, name: "new", aliases: &["draft"], label: "new session tab", keys: "Ctrl-t", group: "sessions", args: "" },
    ActionDef { action: Action::NewForm, name: "form", aliases: &[], label: "new session form (agent, name, directory, permissions)", keys: "", group: "sessions", args: "" },
    ActionDef { action: Action::NextSession, name: "next", aliases: &[], label: "next session", keys: "Ctrl-n (sidebar)", group: "sessions", args: "" },
    ActionDef { action: Action::PrevSession, name: "prev", aliases: &["previous"], label: "previous session", keys: "Ctrl-p (sidebar)", group: "sessions", args: "" },
    ActionDef { action: Action::Rename, name: "rename", aliases: &[], label: "rename the session", keys: "r (sidebar)", group: "sessions", args: "NAME" },
    ActionDef { action: Action::Fork, name: "fork", aliases: &[], label: "fork the session with its history", keys: "f (sidebar)", group: "sessions", args: "" },
    ActionDef { action: Action::Stop, name: "stop", aliases: &["kill"], label: "stop the agent process (session stays resumable)", keys: "x (sidebar)", group: "sessions", args: "" },
    ActionDef { action: Action::Delete, name: "delete", aliases: &["purge"], label: "delete the session and its history", keys: "X (sidebar)", group: "sessions", args: "" },
    ActionDef { action: Action::Export, name: "export", aliases: &[], label: "export a session bundle", keys: "", group: "sessions", args: "[DEST]" },
    ActionDef { action: Action::Import, name: "import", aliases: &[], label: "import a session bundle", keys: "", group: "sessions", args: "PATH" },
    ActionDef { action: Action::Send, name: "send", aliases: &[], label: "send the message", keys: "Enter", group: "talking", args: "" },
    ActionDef { action: Action::Steer, name: "steer", aliases: &[], label: "steer the running turn, or queue when the agent cannot steer", keys: "Ctrl-s", group: "talking", args: "" },
    ActionDef { action: Action::Cancel, name: "cancel", aliases: &["interrupt", "pause"], label: "interrupt the running turn", keys: "Esc  Ctrl-x", group: "talking", args: "" },
    ActionDef { action: Action::Allow, name: "allow", aliases: &["yes"], label: "allow the pending permission", keys: "y", group: "talking", args: "" },
    ActionDef { action: Action::Deny, name: "deny", aliases: &["no"], label: "reject the pending permission", keys: "n", group: "talking", args: "" },
    ActionDef { action: Action::Model, name: "model", aliases: &["harness"], label: "pick harness and model", keys: "Ctrl-l", group: "settings", args: "[MODEL]" },
    ActionDef { action: Action::Mode, name: "mode", aliases: &[], label: "pick the agent mode", keys: "Ctrl-o", group: "settings", args: "[MODE]" },
    ActionDef { action: Action::Effort, name: "effort", aliases: &["thinking", "reasoning"], label: "pick the thinking effort", keys: "Alt-e", group: "settings", args: "[LEVEL]" },
    ActionDef { action: Action::Policy, name: "policy", aliases: &["perms", "permissions"], label: "permission policy: ask · approve-reads · approve-edits · approve-all · deny-all", keys: "", group: "settings", args: "[POLICY]" },
    ActionDef { action: Action::Directory, name: "cwd", aliases: &["dir", "directory"], label: "working directory (a live session forks into a new tab)", keys: "", group: "settings", args: "[PATH]" },
    ActionDef { action: Action::Agent, name: "harness", aliases: &[], label: "harness for the current draft", keys: "", group: "settings", args: "NAME" },
    ActionDef { action: Action::Set, name: "set", aliases: &["config", "option"], label: "any agent option: /set KEY or /set KEY=VALUE", keys: "", group: "settings", args: "KEY[=VALUE]" },
    ActionDef { action: Action::ToggleSystem, name: "system", aliases: &["events", "lifecycle"], label: "show or hide lifecycle events (stopped, resumed, renamed, model set)", keys: "", group: "reading", args: "" },
    ActionDef { action: Action::ToggleThoughts, name: "thoughts", aliases: &["thinking-text"], label: "show or hide the agent's thinking text", keys: "", group: "reading", args: "" },
    ActionDef { action: Action::ScrollTop, name: "top", aliases: &[], label: "scroll to the top", keys: "Home  g (transcript)", group: "reading", args: "" },
    ActionDef { action: Action::ScrollBottom, name: "bottom", aliases: &["follow"], label: "scroll to the bottom and follow", keys: "End  G (transcript)", group: "reading", args: "" },
    ActionDef { action: Action::PageUp, name: "pageup", aliases: &[], label: "scroll up one page", keys: "PgUp", group: "reading", args: "" },
    ActionDef { action: Action::PageDown, name: "pagedown", aliases: &[], label: "scroll down one page", keys: "PgDn", group: "reading", args: "" },
    ActionDef { action: Action::FocusSidebar, name: "sidebar", aliases: &["focus-sidebar"], label: "focus the sidebar", keys: "Cmd-Ctrl-h  Alt-h  Tab", group: "focus", args: "" },
    ActionDef { action: Action::FocusContent, name: "content", aliases: &["focus-content"], label: "focus the content area", keys: "Cmd-Ctrl-l  Alt-l", group: "focus", args: "" },
    ActionDef { action: Action::FocusTranscript, name: "transcript", aliases: &["focus-transcript"], label: "focus the transcript (j/k scroll)", keys: "Cmd-Ctrl-k  Alt-k", group: "focus", args: "" },
    ActionDef { action: Action::FocusComposer, name: "composer", aliases: &["focus-composer", "input"], label: "focus the composer", keys: "Cmd-Ctrl-j  Alt-j", group: "focus", args: "" },
    ActionDef { action: Action::ToggleSidebar, name: "toggle-sidebar", aliases: &["hide-sidebar", "show-sidebar"], label: "hide or show the sidebar", keys: "Alt-s", group: "focus", args: "" },
    ActionDef { action: Action::SidebarNarrow, name: "narrow", aliases: &[], label: "narrow the sidebar", keys: "Alt-Left", group: "focus", args: "" },
    ActionDef { action: Action::SidebarWiden, name: "widen", aliases: &[], label: "widen the sidebar", keys: "Alt-Right", group: "focus", args: "" },
    ActionDef { action: Action::AddHost, name: "host", aliases: &["peer", "add-host"], label: "mirror another machine over ssh", keys: "", group: "hosts", args: "add NAME URL | rm NAME" },
    ActionDef { action: Action::RemoveHost, name: "remove-host", aliases: &["peer-rm"], label: "remove a host", keys: "", group: "hosts", args: "NAME" },
    ActionDef { action: Action::Undo, name: "undo", aliases: &[], label: "undo in the composer", keys: "Ctrl-z", group: "editing", args: "" },
];

/// Keys that are not actions but belong in the help dialog.
pub const EDITING_KEYS: &[(&str, &str)] = &[
    ("Ctrl-j", "newline (also Shift-Enter, or a trailing \\ then Enter)"),
    ("Ctrl-n / Ctrl-p", "next / previous line in the composer; history at the ends"),
    ("Ctrl-a / Ctrl-e", "start / end of line"),
    ("Alt-b / Alt-f", "word left / right"),
    ("Ctrl-w  Alt-d", "delete word back / forward"),
    ("Ctrl-k / Ctrl-u", "kill to end / start of line"),
    ("1-9", "answer a permission request by number"),
    ("wheel", "scroll the transcript; drag selects and copies; double / triple click selects a word / line"),
    ("drag the sidebar rule", "resize the sidebar"),
];

pub fn find(name: &str) -> Option<&'static ActionDef> {
    let n = name.trim_start_matches('/');
    ACTIONS.iter().find(|d| d.name == n || d.aliases.contains(&n))
}

pub fn def(action: Action) -> &'static ActionDef {
    ACTIONS.iter().find(|d| d.action == action).expect("every action is in ACTIONS")
}

/// Effort levels offered for a draft, before the harness can be asked.
/// Codex uses ultra as its top level; Claude Code stops at max.
pub fn draft_effort_levels(agent: &str) -> Vec<(&'static str, &'static str)> {
    if agent.contains("codex") {
        vec![("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Xhigh"), ("max", "Max"), ("ultra", "Ultra")]
    } else {
        vec![("default", "Default (model's choice)"), ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Xhigh"), ("max", "Max")]
    }
}

impl App {
    /// `/name args` from the command line or the palette.
    pub(super) fn run_command(&mut self, line: &str) {
        let line = line.trim().trim_start_matches('/');
        let mut parts = line.split_whitespace();
        let Some(cmd) = parts.next() else { return };
        let rest: Vec<&str> = parts.collect();
        match find(cmd) {
            Some(d) => self.run_action(d.action, &rest),
            None => self.report_error(format!("unknown command /{cmd}  (/ lists every command)")),
        }
    }

    pub(super) fn open_palette(&mut self) {
        let mut rows = Vec::new();
        let mut group = "";
        for d in ACTIONS {
            if d.group != group {
                group = d.group;
                rows.push(PickRow { value: String::new(), label: group.to_owned(), header: true, group: String::new(), note: String::new() });
            }
            let label = if d.keys.is_empty() { format!("/{:<14} {}", d.name, d.label) } else { format!("/{:<14} {}   [{}]", d.name, d.label, d.keys) };
            rows.push(PickRow { value: d.name.to_owned(), label, header: false, group: String::new(), note: String::new() });
        }
        self.overlay = Overlay::Picker(Picker::new("Commands", rows, None, PickTarget::Action, "type to filter · Enter runs · add arguments after a space · Esc"));
    }

    pub(super) fn run_action(&mut self, action: Action, args: &[&str]) {
        let sid = self.selected_id();
        match action {
            Action::Palette => self.open_palette(),
            Action::Help => self.overlay = Overlay::Help,
            Action::Quit => self.quit = true,
            Action::NewDraft => self.open_draft(),
            Action::NewForm => self.open_new_session(),
            Action::NextSession => self.select(self.selected + 1),
            Action::PrevSession => self.select(self.selected.saturating_sub(1)),
            Action::FocusSidebar => self.focus_nav('h'),
            Action::FocusContent => self.focus_nav('l'),
            Action::FocusTranscript => self.focus_nav('k'),
            Action::FocusComposer => {
                self.focus_nav('j');
                if self.focus == Focus::Sidebar {
                    self.focus = Focus::Input;
                }
            }
            Action::ToggleSidebar => self.toggle_sidebar(),
            Action::SidebarNarrow => {
                let cur = self.sidebar_width.unwrap_or(render::SIDEBAR_WIDTH);
                self.sidebar_width = Some(cur.saturating_sub(2).max(16));
            }
            Action::SidebarWiden => {
                let cur = self.sidebar_width.unwrap_or(render::SIDEBAR_WIDTH);
                let total = self.areas.sidebar.width + self.areas.transcript.width;
                self.sidebar_width = Some((cur + 2).min(total.saturating_sub(render::MIN_MAIN_WIDTH)));
            }
            Action::Send => self.send_prompt(false),
            Action::Steer => self.send_prompt(true),
            Action::Cancel => self.cancel(),
            Action::Stop | Action::Delete => {
                if let Some(id) = sid {
                    let purge = action == Action::Delete;
                    self.overlay = Overlay::Confirm {
                        title: format!("{} {}?", if purge { "Delete" } else { "Stop" }, self.selected_name()),
                        action: ConfirmAction::Kill { id, purge },
                    };
                }
            }
            Action::Rename => match (sid, args.first()) {
                (Some(id), Some(name)) => self.request_bg(method::MUX_RENAME, json!({"sessionId": id, "newName": name}), Some("renamed".into())),
                (Some(_), None) => self.prompt_command("rename"),
                _ => {}
            },
            Action::Fork => {
                if let Some(id) = sid {
                    let mut p = json!({"sessionId": id, "mcpServers": [], "_meta": {"acpmux": {}}});
                    if let Some(n) = args.first() {
                        p["_meta"]["acpmux"]["name"] = json!(n);
                    }
                    self.request_bg(method::SESSION_FORK, p, Some("forked".into()));
                }
            }
            Action::Model => match (sid, args.first(), self.on_draft()) {
                (Some(id), Some(m), false) => {
                    self.request_bg(method::SESSION_SET_MODEL, json!({"sessionId": id.clone(), "modelId": m}), Some(format!("model {m}")));
                    self.refresh_detail_later(&id);
                }
                (_, Some(m), true) => {
                    if let Some(d) = self.draft_mut() {
                        d.model = Some(m.to_string());
                    }
                }
                _ => self.open_model_picker(),
            },
            Action::Mode => match (sid, args.first()) {
                (Some(id), Some(m)) => {
                    self.request_bg(method::SESSION_SET_MODE, json!({"sessionId": id.clone(), "modeId": m}), Some(format!("mode {m}")));
                    self.refresh_detail_later(&id);
                }
                _ => self.open_mode_picker(),
            },
            Action::Effort => match args.first() {
                Some(level) => self.set_effort(level.to_string()),
                None => self.open_thinking_picker(),
            },
            Action::Policy => match args.first() {
                Some(p) if self.on_draft() => {
                    if POLICIES.contains(p) {
                        self.draft_mut().unwrap().policy = p.to_string();
                        self.status = format!("draft policy: {p}");
                    } else {
                        self.report_error(format!("policy must be one of {}", POLICIES.join(", ")));
                    }
                }
                Some(p) => {
                    if let Some(id) = sid {
                        self.request_bg(method::MUX_SET_POLICY, json!({"sessionId": id, "policy": p}), Some(format!("policy {p}")));
                    }
                }
                None => self.open_policy_picker(),
            },
            Action::Directory => match args.first() {
                Some(p) => self.apply_directory(p.to_string()),
                None => self.open_directory_dialog(),
            },
            Action::Agent => {
                let known = self.harnesses.clone();
                match (self.draft_mut(), args.first()) {
                    (Some(d), Some(a)) => {
                        if known.iter().any(|x| x == a) {
                            d.harness = a.to_string();
                            self.status = format!("draft harness: {a}");
                        } else {
                            self.report_error(format!("unknown harness {a}; known: {}", known.join(", ")));
                        }
                    }
                    (None, _) => self.report_error("/agent only applies to a new session tab (Ctrl-t); use /model on a live session".into()),
                    (Some(_), None) => self.open_model_picker(),
                }
            }
            Action::Set => match (sid, args.first()) {
                (Some(id), Some(kv)) => {
                    if let Some((k, v)) = kv.split_once('=') {
                        let value = match v {
                            "true" => json!(true),
                            "false" => json!(false),
                            s => json!(s),
                        };
                        self.request_bg(method::SESSION_SET_CONFIG_OPTION, json!({"sessionId": id.clone(), "configId": k, "value": value}), Some(format!("{k} set")));
                        self.refresh_detail_later(&id);
                    } else {
                        self.open_config_picker(kv);
                    }
                }
                (Some(_), None) => self.prompt_command("set"),
                _ => self.report_error("/set needs a live session".into()),
            },
            Action::ToggleThoughts => {
                self.show_thoughts = !self.show_thoughts;
                self.status = format!("thinking text {}", if self.show_thoughts { "shown" } else { "hidden" });
            }
            Action::ToggleSystem => {
                self.show_system = !self.show_system;
                self.status = format!("lifecycle events {}", if self.show_system { "shown" } else { "hidden" });
            }
            Action::Allow => self.answer_permission(PermChoice::Allow),
            Action::Deny => self.answer_permission(PermChoice::Deny),
            Action::ScrollTop => self.with_viewport(|v| v.to_top()),
            Action::ScrollBottom => self.with_viewport(|v| v.to_bottom()),
            Action::PageUp => self.with_viewport(|v| v.page_up()),
            Action::PageDown => self.with_viewport(|v| v.page_down()),
            Action::Web => {
                if let Some(u) = &self.web_url {
                    let _ = std::process::Command::new(if cfg!(target_os = "macos") { "open" } else { "xdg-open" }).arg(u).spawn();
                    self.status = format!("opened {u}");
                }
            }
            Action::AddHost => match args {
                ["add", name, url] => self.request_bg("_acpmux/peer_add", json!({"name": name, "url": url}), Some(format!("host {name} added"))),
                ["add", name, url, token] => self.request_bg("_acpmux/peer_add", json!({"name": name, "url": url, "token": token}), Some(format!("host {name} added"))),
                ["rm", name] | ["remove", name] => self.run_action(Action::RemoveHost, &[name]),
                [] => self.overlay = Overlay::AddHost { text: Editor::default() },
                _ => self.report_error("usage: /host add NAME URL [TOKEN] | /host rm NAME".into()),
            },
            Action::RemoveHost => match args.first() {
                Some(name) => self.request_bg("_acpmux/peer_remove", json!({"name": name}), Some(format!("host {name} removed"))),
                None => self.prompt_command("remove-host"),
            },
            Action::Export => {
                if let Some(id) = sid {
                    let mut p = json!({"sessionId": id});
                    if let Some(d) = args.first() {
                        p["dest"] = json!(d);
                    }
                    self.request_bg(method::MUX_EXPORT, p, Some("exported to ~/.acpmux/bundles".into()));
                }
            }
            Action::Import => match args.first() {
                Some(path) => self.request_bg(method::MUX_IMPORT, json!({"path": path}), Some("imported".into())),
                None => self.prompt_command("import"),
            },
            Action::Undo => self.editor_mut().undo(),
        }
    }

    /// Open the command line with `/name ` typed, for actions that need
    /// arguments.
    pub(super) fn prompt_command(&mut self, name: &str) {
        self.command.set_text(&format!("{name} "));
        self.focus = Focus::Command;
    }

    /// Set the thinking effort on a draft or a live session. The hub maps
    /// `effort` onto whatever option the harness calls it.
    pub(super) fn set_effort(&mut self, level: String) {
        if let Some(d) = self.draft_mut() {
            d.effort = Some(level.clone());
            self.status = format!("draft effort: {level}");
            return;
        }
        if let Some(id) = self.selected_id() {
            self.request_bg(method::SESSION_SET_CONFIG_OPTION, json!({"sessionId": id.clone(), "configId": "effort", "value": level}), Some(format!("effort {level}")));
            self.refresh_detail_later(&id);
        }
    }
}
