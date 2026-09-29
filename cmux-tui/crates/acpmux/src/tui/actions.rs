//! Every user-facing action in one table, like cmux-tui's action registry.
//! The table feeds the command palette, `/name` commands, and the help
//! dialog, so a new action is added in one place. Key chords in `keys.rs`
//! and mouse buttons call `run_action` too, so the palette never disagrees
//! with what a key does.

use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Palette,
    Sessions,
    Skills,
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
    /// Switch to a session by name or title prefix (`/go NAME`).
    Goto,
    Fork,
    Model,
    ReloadCatalog,
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
    ActionDef {
        action: Action::Sessions,
        name: "sessions",
        aliases: &["resume", "continue"],
        label: "switch sessions",
        keys: "",
        group: "sessions",
        args: "",
    },
    ActionDef {
        action: Action::Skills,
        name: "skills",
        aliases: &[],
        label: "insert a skill reference",
        keys: "",
        group: "settings",
        args: "",
    },
    ActionDef {
        action: Action::Palette,
        name: "palette",
        aliases: &["commands"],
        label: "command palette",
        keys: "/  Ctrl-Shift-p  Cmd-k",
        group: "general",
        args: "",
    },
    ActionDef {
        action: Action::Help,
        name: "help",
        aliases: &["keys"],
        label: "all keys",
        keys: "?",
        group: "general",
        args: "",
    },
    ActionDef {
        action: Action::Web,
        name: "web",
        aliases: &[],
        label: "open the web dashboard",
        keys: "",
        group: "general",
        args: "",
    },
    ActionDef {
        action: Action::Quit,
        name: "quit",
        aliases: &["q", "detach", "exit"],
        label: "leave; every agent keeps running",
        keys: "Ctrl-q",
        group: "general",
        args: "",
    },
    ActionDef {
        action: Action::NewDraft,
        name: "new",
        aliases: &["draft", "clear"],
        label: "new session tab",
        keys: "Ctrl-t  Alt-n  Ctrl-x then n",
        group: "sessions",
        args: "",
    },
    ActionDef {
        action: Action::NewForm,
        name: "form",
        aliases: &[],
        label: "new session form (agent, name, directory, permissions)",
        keys: "",
        group: "sessions",
        args: "",
    },
    ActionDef {
        action: Action::NextSession,
        name: "next",
        aliases: &[],
        label: "next session",
        keys: "Ctrl-n (sidebar)  Alt-]",
        group: "sessions",
        args: "",
    },
    ActionDef {
        action: Action::PrevSession,
        name: "prev",
        aliases: &["previous"],
        label: "previous session",
        keys: "Ctrl-p (sidebar)  Alt-[",
        group: "sessions",
        args: "",
    },
    ActionDef {
        action: Action::Goto,
        name: "go",
        aliases: &["goto", "switch", "open"],
        label: "switch to a session by name or title",
        keys: "",
        group: "sessions",
        args: "NAME",
    },
    ActionDef {
        action: Action::Rename,
        name: "rename",
        aliases: &[],
        label: "rename the session",
        keys: "r (sidebar)",
        group: "sessions",
        args: "NAME",
    },
    ActionDef {
        action: Action::Fork,
        name: "fork",
        aliases: &[],
        label: "fork the session with its history",
        keys: "f (sidebar)",
        group: "sessions",
        args: "",
    },
    ActionDef {
        action: Action::Stop,
        name: "stop",
        aliases: &["kill"],
        label: "stop the agent process (session stays resumable)",
        keys: "x (sidebar)",
        group: "sessions",
        args: "",
    },
    ActionDef {
        action: Action::Delete,
        name: "delete",
        aliases: &["purge"],
        label: "delete the session and its history",
        keys: "X (sidebar)",
        group: "sessions",
        args: "",
    },
    ActionDef {
        action: Action::Export,
        name: "export",
        aliases: &[],
        label: "export a session bundle",
        keys: "",
        group: "sessions",
        args: "[DEST]",
    },
    ActionDef {
        action: Action::Import,
        name: "import",
        aliases: &[],
        label: "import a session bundle",
        keys: "",
        group: "sessions",
        args: "PATH",
    },
    ActionDef {
        action: Action::Send,
        name: "send",
        aliases: &[],
        label: "send the message",
        keys: "Enter",
        group: "talking",
        args: "",
    },
    ActionDef {
        action: Action::Steer,
        name: "steer",
        aliases: &[],
        label: "steer the running turn, or queue when the agent cannot steer",
        keys: "Ctrl-s",
        group: "talking",
        args: "",
    },
    ActionDef {
        action: Action::Cancel,
        name: "cancel",
        aliases: &["interrupt", "pause"],
        label: "interrupt the running turn",
        keys: "Esc  Ctrl-g",
        group: "talking",
        args: "",
    },
    ActionDef {
        action: Action::Allow,
        name: "allow",
        aliases: &["yes"],
        label: "allow the pending permission",
        keys: "y",
        group: "talking",
        args: "",
    },
    ActionDef {
        action: Action::Deny,
        name: "deny",
        aliases: &["no"],
        label: "reject the pending permission",
        keys: "n",
        group: "talking",
        args: "",
    },
    ActionDef {
        action: Action::ReloadCatalog,
        name: "reload",
        aliases: &["refresh"],
        label: "reload harness catalog without stopping sessions",
        keys: "",
        group: "settings",
        args: "",
    },
    ActionDef {
        action: Action::Model,
        name: "model",
        aliases: &["models"],
        label: "pick harness and model",
        keys: "Ctrl-l  Alt-m",
        group: "settings",
        args: "[MODEL]",
    },
    ActionDef {
        action: Action::Mode,
        name: "mode",
        aliases: &[],
        label: "pick the agent mode",
        keys: "Ctrl-o",
        group: "settings",
        args: "[MODE]",
    },
    ActionDef {
        action: Action::Effort,
        name: "effort",
        aliases: &["reasoning"],
        label: "pick the thinking effort",
        keys: "Alt-e",
        group: "settings",
        args: "[LEVEL]",
    },
    ActionDef {
        action: Action::Policy,
        name: "policy",
        aliases: &["perms", "permissions"],
        label: "permission policy: ask · approve-reads · approve-edits · approve-all · deny-all",
        keys: "Alt-p",
        group: "settings",
        args: "[POLICY]",
    },
    ActionDef {
        action: Action::Directory,
        name: "cwd",
        aliases: &["dir", "directory", "cd"],
        label: "working directory (a live session forks into a new tab)",
        keys: "Alt-Shift-d",
        group: "settings",
        args: "[PATH]",
    },
    ActionDef {
        action: Action::Agent,
        name: "harness",
        aliases: &[],
        label: "harness for the current draft",
        keys: "",
        group: "settings",
        args: "NAME",
    },
    ActionDef {
        action: Action::Set,
        name: "set",
        aliases: &["config", "option"],
        label: "any agent option: /set KEY or /set KEY=VALUE",
        keys: "",
        group: "settings",
        args: "KEY[=VALUE]",
    },
    ActionDef {
        action: Action::ToggleSystem,
        name: "system",
        aliases: &["events", "lifecycle"],
        label: "show or hide lifecycle events (stopped, resumed, renamed, model set)",
        keys: "",
        group: "reading",
        args: "",
    },
    ActionDef {
        action: Action::ToggleThoughts,
        name: "thoughts",
        aliases: &["thinking-text", "thinking"],
        label: "show or hide the agent's thinking text",
        keys: "",
        group: "reading",
        args: "",
    },
    ActionDef {
        action: Action::ScrollTop,
        name: "top",
        aliases: &[],
        label: "scroll to the top",
        keys: "Home  g (transcript)",
        group: "reading",
        args: "",
    },
    ActionDef {
        action: Action::ScrollBottom,
        name: "bottom",
        aliases: &["follow"],
        label: "scroll to the bottom and follow",
        keys: "End  G (transcript)",
        group: "reading",
        args: "",
    },
    ActionDef {
        action: Action::PageUp,
        name: "pageup",
        aliases: &[],
        label: "scroll up one page",
        keys: "PgUp",
        group: "reading",
        args: "",
    },
    ActionDef {
        action: Action::PageDown,
        name: "pagedown",
        aliases: &[],
        label: "scroll down one page",
        keys: "PgDn",
        group: "reading",
        args: "",
    },
    ActionDef {
        action: Action::FocusSidebar,
        name: "sidebar",
        aliases: &["focus-sidebar"],
        label: "focus the sidebar",
        keys: "Cmd-Ctrl-h  Alt-h  Tab",
        group: "focus",
        args: "",
    },
    ActionDef {
        action: Action::FocusContent,
        name: "content",
        aliases: &["focus-content"],
        label: "focus the content area",
        keys: "Cmd-Ctrl-l  Alt-l",
        group: "focus",
        args: "",
    },
    ActionDef {
        action: Action::FocusTranscript,
        name: "transcript",
        aliases: &["focus-transcript"],
        label: "focus the transcript (j/k scroll)",
        keys: "Cmd-Ctrl-k  Alt-k",
        group: "focus",
        args: "",
    },
    ActionDef {
        action: Action::FocusComposer,
        name: "composer",
        aliases: &["focus-composer", "input"],
        label: "focus the composer",
        keys: "Cmd-Ctrl-j  Alt-j",
        group: "focus",
        args: "",
    },
    ActionDef {
        action: Action::ToggleSidebar,
        name: "toggle-sidebar",
        aliases: &["hide-sidebar", "show-sidebar"],
        label: "hide or show the sidebar",
        keys: "Alt-s",
        group: "focus",
        args: "",
    },
    ActionDef {
        action: Action::SidebarNarrow,
        name: "narrow",
        aliases: &[],
        label: "narrow the sidebar",
        keys: "Alt-Left",
        group: "focus",
        args: "",
    },
    ActionDef {
        action: Action::SidebarWiden,
        name: "widen",
        aliases: &[],
        label: "widen the sidebar",
        keys: "Alt-Right",
        group: "focus",
        args: "",
    },
    ActionDef {
        action: Action::AddHost,
        name: "host",
        aliases: &["peer", "add-host"],
        label: "mirror another machine over ssh",
        keys: "",
        group: "hosts",
        args: "add NAME URL | rm NAME",
    },
    ActionDef {
        action: Action::RemoveHost,
        name: "remove-host",
        aliases: &["peer-rm"],
        label: "remove a host",
        keys: "",
        group: "hosts",
        args: "NAME",
    },
    ActionDef {
        action: Action::Undo,
        name: "undo",
        aliases: &[],
        label: "undo in the composer",
        keys: "Ctrl-z",
        group: "editing",
        args: "",
    },
];

/// Keys that are not actions but belong in the help dialog.
pub const EDITING_KEYS: &[(&str, &str)] = &[
    ("Ctrl-j", "newline (also Shift-Enter, or a trailing \\ then Enter)"),
    ("Ctrl-n / Ctrl-p", "next / previous line in the composer; history at the ends"),
    ("Ctrl-a / Ctrl-e", "start / end of line"),
    ("Alt-b / Alt-f", "word left / right"),
    ("Ctrl-w  Alt-d", "delete word back / forward"),
    ("Ctrl-k / Ctrl-u", "kill to end / start of line"),
    ("Alt-1…9", "jump to a visible session in the sidebar"),
    ("y / n / 1-9", "answer the permission card above the composer"),
    (
        "click",
        "a chip in the composer changes permissions, model or effort; a handle, thought or tool line opens or closes it",
    ),
    (
        "wheel",
        "scroll the transcript; drag selects and copies; double / triple click selects a word / line",
    ),
    ("drag the sidebar edge", "resize the sidebar; hover a session for its details"),
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
        vec![
            ("low", "Low"),
            ("medium", "Medium"),
            ("high", "High"),
            ("xhigh", "Xhigh"),
            ("max", "Max"),
            ("ultra", "Ultra"),
        ]
    } else {
        vec![
            ("default", "Default (model's choice)"),
            ("low", "Low"),
            ("medium", "Medium"),
            ("high", "High"),
            ("xhigh", "Xhigh"),
            ("max", "Max"),
        ]
    }
}

impl App {
    // Used by the draft permission picker already present on main.
    pub(super) fn persist_default_policy(&self, policy: &str) {
        let client = self.client.clone();
        let policy = policy.to_owned();
        tokio::spawn(async move {
            let _ = client.request("_acpmux/set_default_policy", json!({"policy":policy})).await;
        });
    }

    /// `/name args` from the command line or the palette.
    pub(super) fn run_command(&mut self, line: &str) {
        let mut line = line.trim();
        for prefix in std::iter::once(&self.palette_prefix).chain(self.palette_aliases.iter()) {
            if let Some(rest) = line.strip_prefix(prefix) {
                line = rest.trim_start();
                break;
            }
        }
        let mut parts = line.split_whitespace();
        let Some(cmd) = parts.next() else { return };
        let rest: Vec<&str> = parts.collect();
        if matches!(cmd, "cd" | "cwd" | "dir" | "directory") && !rest.is_empty() {
            self.apply_directory(rest.join(" "));
            return;
        }
        match find(cmd) {
            Some(d) => self.run_action(d.action, &rest),
            None if self
                .selected_id()
                .and_then(|id| self.transcripts.get(&id))
                .map(|t| {
                    t.available_commands.iter().any(|name| name.trim_start_matches('/') == cmd)
                })
                .unwrap_or(false) =>
            {
                if let Some(id) = self.selected_id() {
                    let text = format!(
                        "/{cmd}{}",
                        if rest.is_empty() {
                            String::new()
                        } else {
                            format!(" {}", rest.join(" "))
                        }
                    );
                    self.request_bg(
                        method::SESSION_PROMPT,
                        json!({"sessionId": id, "prompt": [{"type":"text", "text":text}]}),
                        None,
                    );
                }
            }
            None => self.report_error(format!(
                "unknown command {}{cmd}  ({} lists every command)",
                self.palette_prefix, self.palette_prefix
            )),
        }
    }

    pub(super) fn open_skill_picker(&mut self) {
        let cwd = self
            .draft()
            .map(|d| d.cwd.clone())
            .or_else(|| {
                self.selected_session()
                    .and_then(|s| s.get("cwd").and_then(Value::as_str).map(str::to_owned))
            })
            .unwrap_or_else(|| {
                std::env::current_dir().unwrap_or_default().to_string_lossy().into_owned()
            });
        if self.remote_directory() {
            self.report_error("Skill browsing currently uses local projects; open a local session to select a skill".into());
            return;
        }
        self.skills =
            crate::tui::skills::Skill::discover(std::path::Path::new(&cwd), &self.skill_paths);
        let rows = self
            .skills
            .iter()
            .map(|s| PickRow {
                value: s.id.clone(),
                label: if s.description.is_empty() {
                    format!("{}{}", self.skill_prefix, s.id)
                } else {
                    format!("{}{:<24} {}", self.skill_prefix, s.id, s.description)
                },
                header: false,
                group: String::new(),
                note: s.path.to_string_lossy().into_owned(),
            })
            .collect();
        self.overlay = Overlay::Picker(Picker::new(
            "Skills",
            rows,
            None,
            PickTarget::Skill { replace_prefix: false },
            "type to filter · Enter inserts · Esc keeps your message",
        ));
    }

    pub(super) fn open_palette(&mut self) {
        let mut rows = Vec::new();
        // Codex app: the palette also switches sessions; they come first.
        if !self.sessions.is_empty() {
            rows.push(PickRow {
                value: String::new(),
                label: "go to".to_owned(),
                header: true,
                group: String::new(),
                note: String::new(),
            });
            for s in &self.sessions {
                let id = s.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
                let title = render::session_title(s);
                let cwd = s.get("cwd").and_then(Value::as_str).unwrap_or("");
                let project = match s.get("peer").and_then(Value::as_str) {
                    Some(p) => format!("{p} · {}", render::project_label(cwd)),
                    None => render::project_label(cwd),
                };
                let status = s.get("status").and_then(Value::as_str).unwrap_or("");
                let mark = match status {
                    "running" => " ●",
                    "waiting" => " ?",
                    _ => "",
                };
                rows.push(PickRow {
                    value: format!("goto:{id}"),
                    label: format!("{title}{mark}   {project}"),
                    header: false,
                    group: String::new(),
                    note: String::new(),
                });
            }
        }
        if let Some(t) = self.selected_id().and_then(|id| self.transcripts.get(&id))
            && !t.available_commands.is_empty()
        {
            rows.push(PickRow {
                value: String::new(),
                label: "harness commands".into(),
                header: true,
                group: String::new(),
                note: String::new(),
            });
            for cmd in &t.available_commands {
                let cmd = cmd.trim_start_matches('/');
                rows.push(PickRow {
                    value: format!("agent:/{cmd}"),
                    label: format!("{}{cmd}", self.palette_prefix),
                    header: false,
                    group: String::new(),
                    note: "provided by the selected harness".into(),
                });
            }
        }
        let mut group = "";
        for d in ACTIONS {
            if d.group != group {
                group = d.group;
                rows.push(PickRow {
                    value: String::new(),
                    label: group.to_owned(),
                    header: true,
                    group: String::new(),
                    note: String::new(),
                });
            }
            let keys = self.keymap.hints(d.name);
            let label = format!("{}{:<14} {}   {}", self.palette_prefix, d.name, d.label, keys);
            rows.push(PickRow {
                value: d.name.to_owned(),
                label,
                header: false,
                group: String::new(),
                note: String::new(),
            });
        }
        self.overlay = Overlay::Picker(Picker::new(
            "Commands",
            rows,
            None,
            PickTarget::Action,
            "type to filter · Enter runs · add arguments after a space · Esc",
        ));
    }

    pub(super) fn run_action(&mut self, action: Action, args: &[&str]) {
        let sid = self.selected_id();
        match action {
            Action::Palette => self.open_palette(),
            Action::Sessions => {
                self.open_palette();
                if let Overlay::Picker(p) = &mut self.overlay {
                    p.title = "Sessions".into();
                    p.rows.retain(|r| r.value.starts_with("goto:"));
                    p.refilter();
                }
            }
            Action::Skills => self.open_skill_picker(),
            Action::Help => self.overlay = Overlay::Help,
            Action::Quit => self.quit = true,
            Action::NewDraft => self.open_draft(),
            Action::NewForm => self.open_new_session(),
            Action::NextSession => self.select_step(1),
            Action::PrevSession => self.select_step(-1),
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
                self.sidebar_width =
                    Some((cur + 2).min(total.saturating_sub(render::MIN_MAIN_WIDTH)));
            }
            Action::Send => self.send_prompt(false),
            Action::Steer => self.send_prompt(true),
            Action::Cancel => self.cancel(),
            Action::Stop | Action::Delete => {
                if let Some(id) = sid {
                    let purge = action == Action::Delete;
                    self.overlay = Overlay::Confirm {
                        title: format!(
                            "{} {}?",
                            if purge { "Delete" } else { "Stop" },
                            self.selected_name()
                        ),
                        action: ConfirmAction::Kill { id, purge },
                    };
                }
            }
            Action::Goto => {
                let want = args.join(" ").to_lowercase();
                let ndrafts = self.drafts.len();
                let hit = self.sessions.iter().position(|s| {
                    let name = s.get("name").and_then(Value::as_str).unwrap_or("").to_lowercase();
                    let title = render::session_title(s).to_lowercase();
                    let sid = s.get("sessionId").and_then(Value::as_str).unwrap_or("");
                    !want.is_empty()
                        && (name == want
                            || sid == want
                            || name.starts_with(&want)
                            || title.starts_with(&want))
                });
                match hit {
                    Some(i) => {
                        self.select(i + ndrafts);
                        self.focus = Focus::Input;
                    }
                    None => self.report_error(format!("no session matches {want:?}")),
                }
            }
            Action::Rename => match (sid, args.first()) {
                (Some(id), Some(name)) => self.request_bg(
                    method::MUX_RENAME,
                    json!({"sessionId": id, "newName": name}),
                    Some("renamed".into()),
                ),
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
                    self.request_bg(
                        method::SESSION_SET_MODEL,
                        json!({"sessionId": id.clone(), "modelId": m}),
                        Some(format!("model {m}")),
                    );
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
                    self.request_bg(
                        method::SESSION_SET_MODE,
                        json!({"sessionId": id.clone(), "modeId": m}),
                        Some(format!("mode {m}")),
                    );
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
                        self.request_bg(
                            method::MUX_SET_POLICY,
                            json!({"sessionId": id, "policy": p}),
                            Some(format!("policy {p}")),
                        );
                    }
                }
                None => self.open_policy_picker(),
            },
            Action::Directory => match args.first() {
                Some(_) => self.apply_directory(args.join(" ")),
                None => self.open_directory_dialog(),
            },
            Action::ReloadCatalog => {
                let client = self.client.clone();
                let tx = self.tx.clone();
                tokio::spawn(async move {
                    match client.request(method::MUX_RELOAD_CONFIG, json!({})).await {
                        Ok(v) => {
                            let names = v
                                .get("harnesses")
                                .and_then(Value::as_array)
                                .into_iter()
                                .flatten()
                                .filter_map(|v| v.as_str().map(str::to_owned))
                                .collect();
                            let default =
                                v.get("defaultHarness").and_then(Value::as_str).map(str::to_owned);
                            let _ = tx.send(AppMsg::Agents(names, default));
                            let _ = tx.send(AppMsg::Info(
                                "catalog reloaded; sessions kept running".into(),
                            ));
                        }
                        Err(e) => {
                            let _ = tx.send(AppMsg::Error(format!("catalog reload: {e}")));
                        }
                    }
                });
                self.status = "reloading catalog…".into();
            }
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
                        self.request_bg(
                            method::SESSION_SET_CONFIG_OPTION,
                            json!({"sessionId": id.clone(), "configId": k, "value": value}),
                            Some(format!("{k} set")),
                        );
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
                self.status = format!(
                    "thinking text {}",
                    if self.show_thoughts { "shown" } else { "hidden" }
                );
            }
            Action::ToggleSystem => {
                self.show_system = !self.show_system;
                self.status = format!(
                    "lifecycle events {}",
                    if self.show_system { "shown" } else { "hidden" }
                );
            }
            Action::Allow => self.answer_permission(PermChoice::Allow),
            Action::Deny => self.answer_permission(PermChoice::Deny),
            Action::ScrollTop => self.with_viewport(|v| v.to_top()),
            Action::ScrollBottom => self.with_viewport(|v| v.to_bottom()),
            Action::PageUp => self.with_viewport(|v| v.page_up()),
            Action::PageDown => self.with_viewport(|v| v.page_down()),
            Action::Web => {
                if let Some(u) = &self.web_url {
                    // Deep link to the selected session; the token stays out of the status bar.
                    let url = match self.selected_id() {
                        Some(id) => format!("{u}&session={id}"),
                        None => u.clone(),
                    };
                    let _ = std::process::Command::new(if cfg!(target_os = "macos") {
                        "open"
                    } else {
                        "xdg-open"
                    })
                    .arg(&url)
                    .spawn();
                    self.status = "opened the web dashboard".into();
                }
            }
            Action::AddHost => match args {
                ["add", name, url] => self.request_bg(
                    "_acpmux/peer_add",
                    json!({"name": name, "url": url}),
                    Some(format!("host {name} added")),
                ),
                ["add", name, url, token] => self.request_bg(
                    "_acpmux/peer_add",
                    json!({"name": name, "url": url, "token": token}),
                    Some(format!("host {name} added")),
                ),
                ["rm", name] | ["remove", name] => self.run_action(Action::RemoveHost, &[name]),
                [] => self.overlay = Overlay::AddHost { text: Editor::default() },
                _ => self.report_error("usage: /host add NAME URL [TOKEN] | /host rm NAME".into()),
            },
            Action::RemoveHost => match args.first() {
                Some(name) => self.request_bg(
                    "_acpmux/peer_remove",
                    json!({"name": name}),
                    Some(format!("host {name} removed")),
                ),
                None => self.prompt_command("remove-host"),
            },
            Action::Export => {
                if let Some(id) = sid {
                    let mut p = json!({"sessionId": id});
                    if let Some(d) = args.first() {
                        p["dest"] = json!(d);
                    }
                    self.request_bg(
                        method::MUX_EXPORT,
                        p,
                        Some("exported to ~/.acpmux/bundles".into()),
                    );
                }
            }
            Action::Import => match args.first() {
                Some(path) => self.request_bg(
                    method::MUX_IMPORT,
                    json!({"path": path}),
                    Some("imported".into()),
                ),
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
            self.request_bg(
                method::SESSION_SET_CONFIG_OPTION,
                json!({"sessionId": id.clone(), "configId": "effort", "value": level}),
                Some(format!("effort {level}")),
            );
            self.refresh_detail_later(&id);
        }
    }
}
