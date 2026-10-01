//! Part of the TUI `App`; see `tui/mod.rs`.

use super::*;

impl App {
    // ---------------------------------------------------------------- keys

    /// Overlays take every key. Returns true when the key was consumed.
    pub(super) fn on_overlay_key(&mut self, key: KeyEvent) -> bool {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match std::mem::replace(&mut self.overlay, Overlay::None) {
            Overlay::None => false,
            Overlay::Menu(mut m) => {
                match key.code {
                    KeyCode::Esc | KeyCode::Char('q') => {}
                    KeyCode::Up | KeyCode::Char('k') => {
                        m.cursor = m.cursor.saturating_sub(1);
                        self.overlay = Overlay::Menu(m);
                    }
                    KeyCode::Down | KeyCode::Char('j') => {
                        m.cursor = (m.cursor + 1).min(m.items.len().saturating_sub(1));
                        self.overlay = Overlay::Menu(m);
                    }
                    KeyCode::Char('n') if ctrl => {
                        m.cursor = (m.cursor + 1).min(m.items.len().saturating_sub(1));
                        self.overlay = Overlay::Menu(m);
                    }
                    KeyCode::Char('p') if ctrl => {
                        m.cursor = m.cursor.saturating_sub(1);
                        self.overlay = Overlay::Menu(m);
                    }
                    KeyCode::Enter => {
                        if let Some(it) = m.items.get(m.cursor) {
                            let a = it.action.clone();
                            self.run_menu_action(a);
                        }
                    }
                    _ => self.overlay = Overlay::Menu(m),
                }
                true
            }
            Overlay::AddHost { mut text } => {
                match key.code {
                    KeyCode::Esc => {}
                    KeyCode::Enter => {
                        let host = text.text().trim().to_owned();
                        if !host.is_empty() {
                            let name = host
                                .rsplit('@')
                                .next()
                                .unwrap_or(&host)
                                .split(':')
                                .next()
                                .unwrap_or(&host)
                                .to_owned();
                            let url = if host.contains("://") {
                                host.clone()
                            } else {
                                format!("ssh://{host}")
                            };
                            // `wait`: the reply comes once the first connect settled.
                            self.request_then(
                                "_acpmux/peer_add",
                                json!({"name": name, "url": url, "wait": true}),
                                Some(format!("adding host {name}…")),
                                Reread::Status,
                            );
                        }
                    }
                    _ => {
                        editor::handle_key(&mut text, key);
                        self.overlay = Overlay::AddHost { text };
                    }
                }
                true
            }
            Overlay::Directory { mut text } => {
                match key.code {
                    KeyCode::Esc => {}
                    KeyCode::Enter => {
                        let path = text.text().trim().to_owned();
                        if !path.is_empty() {
                            self.apply_directory(path);
                        }
                    }
                    _ => {
                        editor::handle_key(&mut text, key);
                        self.overlay = Overlay::Directory { text };
                    }
                }
                true
            }
            Overlay::Help => {
                match key.code {
                    KeyCode::Esc | KeyCode::Char('?') | KeyCode::Char('q') | KeyCode::Enter => {}
                    KeyCode::Up | KeyCode::Char('k') => {
                        self.dialog.wheel(-1);
                        self.overlay = Overlay::Help;
                    }
                    KeyCode::Down | KeyCode::Char('j') => {
                        self.dialog.wheel(1);
                        self.overlay = Overlay::Help;
                    }
                    KeyCode::PageUp => {
                        self.dialog.viewport.page_up();
                        self.overlay = Overlay::Help;
                    }
                    KeyCode::PageDown => {
                        self.dialog.viewport.page_down();
                        self.overlay = Overlay::Help;
                    }
                    KeyCode::Home => {
                        self.dialog.viewport.to_top();
                        self.overlay = Overlay::Help;
                    }
                    KeyCode::End => {
                        self.dialog.viewport.to_bottom();
                        self.overlay = Overlay::Help;
                    }
                    _ => self.overlay = Overlay::Help,
                }
                true
            }
            Overlay::Confirm { title, action } => {
                match key.code {
                    KeyCode::Char('y') | KeyCode::Enter => match action {
                        ConfirmAction::Kill { id, purge } => {
                            self.request_bg(
                                method::MUX_KILL,
                                json!({"sessionId": id, "purge": purge}),
                                Some(if purge { "deleted".into() } else { "stopped".into() }),
                            );
                            if purge {
                                self.refresh_sessions();
                            }
                        }
                    },
                    KeyCode::Char('n') | KeyCode::Esc => {}
                    _ => self.overlay = Overlay::Confirm { title, action },
                }
                true
            }
            Overlay::Picker(mut p) => {
                let is_agent = matches!(p.on_pick, PickTarget::Agent);
                match key.code {
                    KeyCode::Esc => {
                        if matches!(p.on_pick, PickTarget::Skill { replace_prefix: true }) {
                            self.editor_mut().insert_str(&p.filter.text());
                        }
                    }
                    KeyCode::Up => {
                        p.move_by(-1);
                        self.overlay = Overlay::Picker(p);
                    }
                    KeyCode::Down => {
                        p.move_by(1);
                        self.overlay = Overlay::Picker(p);
                    }
                    KeyCode::Char('n') if ctrl => {
                        p.move_by(1);
                        self.overlay = Overlay::Picker(p);
                    }
                    KeyCode::Char('p') if ctrl => {
                        p.move_by(-1);
                        self.overlay = Overlay::Picker(p);
                    }
                    KeyCode::Enter => {
                        let filter = p.filter.text();
                        if matches!(p.on_pick, PickTarget::Action)
                            && (filter.contains(' ')
                                || filter
                                    .chars()
                                    .next()
                                    .map(|c| self.palette_trigger(c))
                                    .unwrap_or(false))
                        {
                            // "rename foo" typed into the palette runs as a command line.
                            self.run_command(&filter);
                        } else if let Some(row) = p.selected().cloned() {
                            self.apply_pick(p.on_pick.clone(), row.value, row.group);
                        } else if matches!(p.on_pick, PickTarget::Skill { replace_prefix: true }) {
                            self.editor_mut().insert_str(&filter);
                            self.focus = Focus::Input;
                        } else {
                            self.overlay = Overlay::Picker(p);
                        }
                    }
                    KeyCode::PageUp => {
                        for _ in 0..8 {
                            p.move_by(-1);
                        }
                        self.overlay = Overlay::Picker(p);
                    }
                    KeyCode::PageDown => {
                        for _ in 0..8 {
                            p.move_by(1);
                        }
                        self.overlay = Overlay::Picker(p);
                    }
                    _ => {
                        if editor::handle_key(&mut p.filter, key) {
                            p.refilter();
                        }
                        self.overlay = Overlay::Picker(p);
                    }
                }
                if is_agent
                    && matches!(self.overlay, Overlay::None)
                    && let Some(form) = self.parked_form.take()
                {
                    self.overlay = form;
                }
                true
            }
            Overlay::NewSession(mut f) => {
                match key.code {
                    KeyCode::Esc => self.status = DEFAULT_STATUS.into(),
                    KeyCode::Tab | KeyCode::Down => {
                        f.field = (f.field + 1) % 5;
                        self.overlay = Overlay::NewSession(f);
                    }
                    KeyCode::BackTab | KeyCode::Up => {
                        f.field = (f.field + 4) % 5;
                        self.overlay = Overlay::NewSession(f);
                    }
                    KeyCode::Enter => {
                        if f.field == 0 && !f.harnesses.is_empty() {
                            let rows: Vec<PickRow> = f
                                .harnesses
                                .iter()
                                .map(|a| PickRow {
                                    value: a.clone(),
                                    label: a.clone(),
                                    header: false,
                                    group: String::new(),
                                    note: String::new(),
                                })
                                .collect();
                            let cur = f.harnesses.get(f.agent).cloned();
                            self.parked_form = Some(Overlay::NewSession(f));
                            self.overlay = Overlay::Picker(Picker::new(
                                "Agent",
                                rows,
                                cur.as_deref(),
                                PickTarget::Agent,
                                "↑↓ · Enter or click picks · Esc",
                            ));
                        } else {
                            self.submit_new_session(&f);
                        }
                    }
                    KeyCode::Left | KeyCode::Right if f.field == 0 => {
                        if !f.harnesses.is_empty() {
                            f.agent = if key.code == KeyCode::Right {
                                (f.agent + 1) % f.harnesses.len()
                            } else {
                                (f.agent + f.harnesses.len() - 1) % f.harnesses.len()
                            };
                        }
                        self.overlay = Overlay::NewSession(f);
                    }
                    KeyCode::Left | KeyCode::Right if f.field == 3 => {
                        f.policy = if key.code == KeyCode::Right {
                            (f.policy + 1) % POLICIES.len()
                        } else {
                            (f.policy + POLICIES.len() - 1) % POLICIES.len()
                        };
                        self.overlay = Overlay::NewSession(f);
                    }
                    KeyCode::Char(c) if f.field == 0 && !ctrl => {
                        if let Some(i) = f.harnesses.iter().position(|a| a.starts_with(c)) {
                            f.agent = i;
                        }
                        self.overlay = Overlay::NewSession(f);
                    }
                    KeyCode::Char(c) if f.field == 3 && !ctrl => {
                        if let Some(i) = POLICIES.iter().position(|p| p.starts_with(c)) {
                            f.policy = i;
                        }
                        self.overlay = Overlay::NewSession(f);
                    }
                    // Session names take only name characters; other fields take anything.
                    KeyCode::Char(c)
                        if f.field == 1
                            && !ctrl
                            && !key.modifiers.contains(KeyModifiers::ALT)
                            && !c.is_ascii_alphanumeric()
                            && !matches!(c, '-' | '_' | '.') =>
                    {
                        self.overlay = Overlay::NewSession(f);
                    }
                    _ => {
                        match f.field {
                            1 => {
                                editor::handle_key(&mut f.name, key);
                            }
                            2 => {
                                editor::handle_key(&mut f.cwd, key);
                            }
                            4 => {
                                editor::handle_key(&mut f.prompt, key);
                            }
                            _ => {}
                        }
                        self.overlay = Overlay::NewSession(f);
                    }
                }
                true
            }
        }
    }

    pub(super) fn toggle_sidebar(&mut self) {
        self.sidebar_hidden = !self.sidebar_hidden;
        if self.sidebar_hidden && self.focus == Focus::Sidebar {
            self.focus = Focus::Input;
        }
    }

    /// h: sidebar, l: content, k: transcript above the composer, j: composer.
    pub(super) fn focus_nav(&mut self, dir: char) {
        if dir == 'h' && self.sidebar_hidden {
            // Moving left into a hidden sidebar shows it, like cmux's focus-sidebar.
            self.sidebar_hidden = false;
        }
        self.focus = match (dir, self.focus) {
            ('h', _) => Focus::Sidebar,
            ('l', Focus::Sidebar) => Focus::Input,
            ('l', f) => f,
            ('k', Focus::Input | Focus::Command) => Focus::Transcript,
            ('k', f) => f,
            ('j', Focus::Transcript) => Focus::Input,
            ('j', f) => f,
            (_, f) => f,
        };
    }

    /// Jump to the visible sidebar row at a number key, as in cmux's pane
    /// shortcuts. The sidebar renderer owns this order so collapsed groups
    /// and host filters behave exactly like mouse/arrow navigation.
    fn select_numbered(&mut self, n: usize) {
        if let Some(&idx) = self.sidebar_order.get(n.saturating_sub(1)) {
            self.select(idx);
            self.focus = Focus::Input;
        }
    }

    fn palette_trigger(&self, c: char) -> bool {
        self.palette_prefix.starts_with(c) || self.palette_aliases.iter().any(|p| p.starts_with(c))
    }

    pub(super) fn on_key(&mut self, key: KeyEvent) {
        if self.on_overlay_key(key) {
            return;
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        // The sidebar steps with Option-j/k (plain j/k do nothing there), ahead of
        // the global Alt-j/k focus bindings, which are no-ops from the sidebar.
        // '∆'/'˚' are what macOS sends when Option is not treated as Meta.
        if self.focus == Focus::Sidebar {
            let alt = key.modifiers.contains(KeyModifiers::ALT);
            match key.code {
                KeyCode::Char('j') if alt => {
                    self.select_step(1);
                    return;
                }
                KeyCode::Char('k') if alt => {
                    self.select_step(-1);
                    return;
                }
                KeyCode::Char('∆') => {
                    self.select_step(1);
                    return;
                }
                KeyCode::Char('˚') => {
                    self.select_step(-1);
                    return;
                }
                _ => {}
            }
        }
        match self.keymap.feed(key) {
            keymap::Match::Run(command) => {
                if let Some(n) = command.strip_prefix("session-").and_then(|s| s.parse().ok()) {
                    self.select_numbered(n);
                } else {
                    self.run_command(&command);
                }
                return;
            }
            keymap::Match::Pending(hint) => {
                self.status = format!("chord · {hint}");
                return;
            }
            keymap::Match::Cancelled => {
                self.status = DEFAULT_STATUS.into();
                return;
            }
            keymap::Match::Pass => {}
        }
        let plain = !key
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER);
        if plain
            && self.focus == Focus::Input
            && let KeyCode::Char(c) = key.code
            && self.skill_prefix.starts_with(c)
            && (self.editor().cursor() == 0
                || self
                    .editor()
                    .text()
                    .chars()
                    .nth(self.editor().cursor() - 1)
                    .map(char::is_whitespace)
                    .unwrap_or(false))
        {
            self.editor_mut().insert(c);
            self.open_skill_picker();
            if let Overlay::Picker(p) = &mut self.overlay {
                p.on_pick = PickTarget::Skill { replace_prefix: true };
            }
            return;
        }
        match key.code {
            KeyCode::Char('n') if ctrl => {
                match self.focus {
                    Focus::Input => self.editor_mut().down(),
                    Focus::Transcript => self.with_viewport(|v| v.scroll_by(1)),
                    _ => self.select_step(1),
                };
                return;
            }
            KeyCode::Char('p') if ctrl => {
                match self.focus {
                    Focus::Input => self.editor_mut().up(),
                    Focus::Transcript => self.with_viewport(|v| v.scroll_by(-1)),
                    _ => self.select_step(-1),
                };
                return;
            }
            KeyCode::Left
                if key.modifiers == KeyModifiers::ALT
                    && (self.focus == Focus::Sidebar || self.editor().is_empty()) =>
            {
                self.run_action(Action::SidebarNarrow, &[]);
                return;
            }
            KeyCode::Right
                if key.modifiers == KeyModifiers::ALT
                    && (self.focus == Focus::Sidebar || self.editor().is_empty()) =>
            {
                self.run_action(Action::SidebarWiden, &[]);
                return;
            }
            KeyCode::Home if self.focus != Focus::Input && self.editor().is_empty() => {
                self.with_viewport(|v| v.to_top());
                return;
            }
            KeyCode::End if self.editor().is_empty() => {
                self.with_viewport(|v| v.to_bottom());
                return;
            }
            _ => {}
        }
        // Typing clears a selection, as in cmux.
        if matches!(key.code, KeyCode::Char(_)) && !ctrl {
            self.selection = None;
        }
        match self.focus {
            Focus::Command => match key.code {
                KeyCode::Esc => {
                    self.command.clear();
                    self.focus = Focus::Input;
                }
                KeyCode::Enter => {
                    let line = self.command.take();
                    self.focus = Focus::Input;
                    if !line.trim().is_empty() {
                        self.run_command(&line);
                    }
                }
                // Backspace past the '/' returns to the message editor.
                KeyCode::Backspace if self.command.is_empty() => self.focus = Focus::Input,
                KeyCode::Char('c') if ctrl => {
                    self.command.clear();
                    self.focus = Focus::Input;
                }
                _ => {
                    editor::handle_key(&mut self.command, key);
                }
            },
            Focus::Transcript => match key.code {
                KeyCode::Esc | KeyCode::Enter | KeyCode::Tab | KeyCode::Char('i') => {
                    self.focus = Focus::Input
                }
                KeyCode::Char('j') | KeyCode::Down => self.with_viewport(|v| v.scroll_by(1)),
                KeyCode::Char('k') | KeyCode::Up => self.with_viewport(|v| v.scroll_by(-1)),
                KeyCode::Char('d') => self.with_viewport(|v| v.page_down()),
                KeyCode::Char('u') => self.with_viewport(|v| v.page_up()),
                KeyCode::Char('g') | KeyCode::Home => self.with_viewport(|v| v.to_top()),
                KeyCode::Char('G') | KeyCode::End => self.with_viewport(|v| v.to_bottom()),
                KeyCode::Char(c) if plain && self.palette_trigger(c) => {
                    self.run_action(Action::Palette, &[])
                }
                KeyCode::Char('?') => self.run_action(Action::Help, &[]),
                KeyCode::Char('y') => self.run_action(Action::Allow, &[]),
                KeyCode::Char('n') => self.run_action(Action::Deny, &[]),
                KeyCode::Char('x') => self.run_action(Action::Cancel, &[]),
                _ => {}
            },
            Focus::Sidebar => match key.code {
                KeyCode::Esc | KeyCode::Tab => self.focus = Focus::Input,
                KeyCode::Down => self.select_step(1),
                KeyCode::Up => self.select_step(-1),
                KeyCode::Enter => self.focus = Focus::Input,
                KeyCode::Char(c) if plain && self.palette_trigger(c) => {
                    self.run_action(Action::Palette, &[])
                }
                KeyCode::Char('?') => self.run_action(Action::Help, &[]),
                KeyCode::Char('n') => self.run_action(Action::NewDraft, &[]),
                KeyCode::Char('x') => self.run_action(Action::Stop, &[]),
                KeyCode::Char('X') => self.run_action(Action::Delete, &[]),
                KeyCode::Char('r') => self.run_action(Action::Rename, &[]),
                KeyCode::Char('f') => self.run_action(Action::Fork, &[]),
                KeyCode::Char('m') => self.run_action(Action::Model, &[]),
                KeyCode::Char('o') => self.run_action(Action::Mode, &[]),
                KeyCode::Char('e') => self.run_action(Action::Effort, &[]),
                KeyCode::Char('y') => self.run_action(Action::Allow, &[]),
                KeyCode::Char('d') => self.run_action(Action::Deny, &[]),
                _ => {}
            },
            Focus::Input => {
                let has_pending = self
                    .selected_id()
                    .and_then(|id| self.transcripts.get(&id))
                    .map(|t| t.pending_permission().is_some())
                    .unwrap_or(false);
                if has_pending && self.editor().is_empty() {
                    match key.code {
                        KeyCode::Char('y') => return self.answer_permission(PermChoice::Allow),
                        KeyCode::Char('n') => return self.answer_permission(PermChoice::Deny),
                        KeyCode::Char(c) if c.is_ascii_digit() && c != '0' => {
                            return self
                                .answer_permission(PermChoice::Index(c as usize - '1' as usize));
                        }
                        _ => {}
                    }
                }
                let alt = key.modifiers.contains(KeyModifiers::ALT);
                let shift = key.modifiers.contains(KeyModifiers::SHIFT);
                match key.code {
                    KeyCode::Tab => self.focus = Focus::Sidebar,
                    // Esc interrupts a running agent first, like Claude Code.
                    KeyCode::Esc => {
                        let list_running = self
                            .selected_session()
                            .and_then(|s| s.get("status"))
                            .and_then(Value::as_str)
                            == Some("running");
                        let transcript_running = self
                            .selected_id()
                            .and_then(|id| self.transcripts.get(&id))
                            .map(|t| t.status == "running")
                            .unwrap_or(false);
                        if list_running || transcript_running {
                            self.run_action(Action::Cancel, &[]);
                        } else if !self.editor().is_empty() {
                            self.editor_mut().clear();
                        } else if self.on_draft() {
                            self.discard_draft();
                        }
                    }
                    KeyCode::Char(c)
                        if plain && self.editor().is_empty() && self.palette_trigger(c) =>
                    {
                        self.run_action(Action::Palette, &[])
                    }
                    KeyCode::Char('?') if self.editor().is_empty() => {
                        self.run_action(Action::Help, &[])
                    }
                    KeyCode::Enter if alt || shift => self.editor_mut().insert('\n'),
                    KeyCode::Char('j') if ctrl => self.editor_mut().insert('\n'),
                    KeyCode::Enter => {
                        if self.editor_mut().enter_means_newline() {
                            self.editor_mut().replace_trailing_backslash_with_newline();
                        } else {
                            self.send_prompt(false);
                        }
                    }
                    _ => {
                        editor::handle_key(self.editor_mut(), key);
                    }
                }
            }
        }
    }
}
