//! Part of the TUI `App`; see `tui/mod.rs`.

use super::*;

impl App {
    // ---------------------------------------------------------------- keys

    /// Overlays take every key. Returns true when the key was consumed.
    pub(super) fn on_overlay_key(&mut self, key: KeyEvent) -> bool {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match std::mem::replace(&mut self.overlay, Overlay::None) {
            Overlay::None => false,
            Overlay::AddHost { mut text } => {
                match key.code {
                    KeyCode::Esc => {}
                    KeyCode::Enter => {
                        let host = text.text().trim().to_owned();
                        if !host.is_empty() {
                            let name = host.rsplit('@').next().unwrap_or(&host).split(':').next().unwrap_or(&host).to_owned();
                            let url = if host.contains("://") { host.clone() } else { format!("ssh://{host}") };
                            self.request_bg("_acpmux/peer_add", json!({"name": name, "url": url}), Some(format!("adding host {name}…")));
                            let c = self.client.clone();
                            let tx = self.tx.clone();
                            tokio::spawn(async move {
                                tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                                if let Ok(v) = c.request(method::MUX_STATUS, json!({})).await {
                                    let _ = tx.send(AppMsg::Status(v));
                                }
                            });
                        }
                    }
                    KeyCode::Backspace => { text.backspace(); self.overlay = Overlay::AddHost { text }; }
                    KeyCode::Left => { text.left(); self.overlay = Overlay::AddHost { text }; }
                    KeyCode::Right => { text.right(); self.overlay = Overlay::AddHost { text }; }
                    KeyCode::Home => { text.home(); self.overlay = Overlay::AddHost { text }; }
                    KeyCode::End => { text.end(); self.overlay = Overlay::AddHost { text }; }
                    KeyCode::Char('u') if ctrl => { text.clear(); self.overlay = Overlay::AddHost { text }; }
                    KeyCode::Char(ch) if !ctrl => { text.insert(ch); self.overlay = Overlay::AddHost { text }; }
                    _ => self.overlay = Overlay::AddHost { text },
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
                    KeyCode::Backspace => { text.backspace(); self.overlay = Overlay::Directory { text }; }
                    KeyCode::Left => { text.left(); self.overlay = Overlay::Directory { text }; }
                    KeyCode::Right => { text.right(); self.overlay = Overlay::Directory { text }; }
                    KeyCode::Home => { text.home(); self.overlay = Overlay::Directory { text }; }
                    KeyCode::End => { text.end(); self.overlay = Overlay::Directory { text }; }
                    KeyCode::Char('u') if ctrl => { text.clear(); self.overlay = Overlay::Directory { text }; }
                    KeyCode::Char('w') if ctrl => { text.delete_word_back(); self.overlay = Overlay::Directory { text }; }
                    KeyCode::Char(ch) if !ctrl => { text.insert(ch); self.overlay = Overlay::Directory { text }; }
                    _ => self.overlay = Overlay::Directory { text },
                }
                true
            }
            Overlay::Help => {
                match key.code {
                    KeyCode::Esc | KeyCode::Char('?') | KeyCode::Char('q') | KeyCode::Enter => {}
                    KeyCode::Up | KeyCode::Char('k') => { self.dialog.wheel(-1); self.overlay = Overlay::Help; }
                    KeyCode::Down | KeyCode::Char('j') => { self.dialog.wheel(1); self.overlay = Overlay::Help; }
                    KeyCode::PageUp => { self.dialog.viewport.page_up(); self.overlay = Overlay::Help; }
                    KeyCode::PageDown => { self.dialog.viewport.page_down(); self.overlay = Overlay::Help; }
                    KeyCode::Home => { self.dialog.viewport.to_top(); self.overlay = Overlay::Help; }
                    KeyCode::End => { self.dialog.viewport.to_bottom(); self.overlay = Overlay::Help; }
                    _ => self.overlay = Overlay::Help,
                }
                true
            }
            Overlay::Confirm { title, action } => {
                match key.code {
                    KeyCode::Char('y') | KeyCode::Enter => match action {
                        ConfirmAction::Kill { id, purge } => {
                            self.request_bg(method::MUX_KILL, json!({"sessionId": id, "purge": purge}), Some(if purge { "deleted".into() } else { "stopped".into() }));
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
                    KeyCode::Esc => {}
                    KeyCode::Up => { p.move_by(-1); self.overlay = Overlay::Picker(p); }
                    KeyCode::Down => { p.move_by(1); self.overlay = Overlay::Picker(p); }
                    KeyCode::Char('n') if ctrl => { p.move_by(1); self.overlay = Overlay::Picker(p); }
                    KeyCode::Char('p') if ctrl => { p.move_by(-1); self.overlay = Overlay::Picker(p); }
                    KeyCode::Enter => {
                        if let Some(row) = p.selected().cloned() {
                            self.apply_pick(p.on_pick.clone(), row.value, row.group);
                        }
                    }
                    KeyCode::PageUp => { for _ in 0..8 { p.move_by(-1); } self.overlay = Overlay::Picker(p); }
                    KeyCode::PageDown => { for _ in 0..8 { p.move_by(1); } self.overlay = Overlay::Picker(p); }
                    KeyCode::Backspace => { p.filter.pop(); p.refilter(); self.overlay = Overlay::Picker(p); }
                    KeyCode::Char('u') if ctrl => { p.filter.clear(); p.refilter(); self.overlay = Overlay::Picker(p); }
                    KeyCode::Char(ch) if !ctrl => { p.filter.push(ch); p.refilter(); self.overlay = Overlay::Picker(p); }
                    _ => self.overlay = Overlay::Picker(p),
                }
                if is_agent && matches!(self.overlay, Overlay::None) {
                    if let Some(form) = self.parked_form.take() {
                        self.overlay = form;
                    }
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
                        if f.field == 0 && !f.agents.is_empty() {
                            let rows: Vec<PickRow> = f.agents.iter().map(|a| PickRow { value: a.clone(), label: a.clone(), header: false, group: String::new(), note: String::new() }).collect();
                            let cur = f.agents.get(f.agent).cloned();
                            self.parked_form = Some(Overlay::NewSession(f));
                            self.overlay = Overlay::Picker(Picker::new("Agent", rows, cur.as_deref(), PickTarget::Agent, "↑↓ · Enter or click picks · Esc"));
                        } else {
                            self.submit_new_session(&f);
                        }
                    }
                    KeyCode::Left | KeyCode::Right if f.field == 0 => {
                        if !f.agents.is_empty() {
                            f.agent = if key.code == KeyCode::Right { (f.agent + 1) % f.agents.len() } else { (f.agent + f.agents.len() - 1) % f.agents.len() };
                        }
                        self.overlay = Overlay::NewSession(f);
                    }
                    KeyCode::Left | KeyCode::Right if f.field == 3 => {
                        f.policy = if key.code == KeyCode::Right { (f.policy + 1) % POLICIES.len() } else { (f.policy + POLICIES.len() - 1) % POLICIES.len() };
                        self.overlay = Overlay::NewSession(f);
                    }
                    KeyCode::Backspace => {
                        match f.field {
                            1 => {
                                f.name.pop();
                            }
                            2 => {
                                f.cwd.pop();
                            }
                            4 => {
                                f.prompt.pop();
                            }
                            _ => {}
                        }
                        self.overlay = Overlay::NewSession(f);
                    }
                    KeyCode::Char('u') if ctrl => {
                        match f.field {
                            1 => f.name.clear(),
                            2 => f.cwd.clear(),
                            4 => f.prompt.clear(),
                            _ => {}
                        }
                        self.overlay = Overlay::NewSession(f);
                    }
                    KeyCode::Char(c) if !ctrl => {
                        match f.field {
                            1 => {
                                if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') {
                                    f.name.push(c)
                                }
                            }
                            2 => f.cwd.push(c),
                            4 => f.prompt.push(c),
                            0 => {
                                if let Some(i) = f.agents.iter().position(|a| a.starts_with(c)) {
                                    f.agent = i
                                }
                            }
                            3 => {
                                if let Some(i) = POLICIES.iter().position(|p| p.starts_with(c)) {
                                    f.policy = i
                                }
                            }
                            _ => {}
                        }
                        self.overlay = Overlay::NewSession(f);
                    }
                    _ => self.overlay = Overlay::NewSession(f),
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

    pub(super) fn on_key(&mut self, key: KeyEvent) {
        if self.on_overlay_key(key) {
            return;
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        // Focus moves like cmux panes: Cmd-Ctrl-h/j/k/l, or Alt-h/j/k/l on
        // terminals that do not deliver Cmd.
        let nav = key.modifiers.contains(KeyModifiers::SUPER) || (key.modifiers.contains(KeyModifiers::ALT) && !ctrl);
        if let (KeyCode::Char(c @ ('h' | 'j' | 'k' | 'l')), true) = (key.code, nav) {
            self.focus_nav(c);
            return;
        }
        if let (KeyCode::Char('s'), true) = (key.code, key.modifiers.contains(KeyModifiers::ALT) && !ctrl) {
            self.toggle_sidebar();
            return;
        }
        match (key.code, ctrl) {
            (KeyCode::Char('q'), true) => {
                self.quit = true;
                return;
            }
            (KeyCode::Char('t'), true) => {
                self.open_draft();
                return;
            }
            (KeyCode::Char('z'), true) => {
                self.editor_mut().undo();
                return;
            }
            // Emacs next/previous line in the composer; next/previous
            // session when the sidebar or transcript has focus.
            (KeyCode::Char('n'), true) => {
                match self.focus {
                    Focus::Input => self.editor_mut().down(),
                    Focus::Transcript => self.with_viewport(|v| v.scroll_by(1)),
                    _ => self.select(self.selected + 1),
                }
                return;
            }
            (KeyCode::Char('p'), true) => {
                match self.focus {
                    Focus::Input => self.editor_mut().up(),
                    Focus::Transcript => self.with_viewport(|v| v.scroll_by(-1)),
                    _ => self.select(self.selected.saturating_sub(1)),
                }
                return;
            }
            (KeyCode::Char('x'), true) => {
                self.cancel();
                return;
            }
            // Ctrl-m is Enter on most terminals, so model lives on Ctrl-l.
            (KeyCode::Char('l'), true) => {
                self.open_model_picker();
                return;
            }
            (KeyCode::Char('o'), true) => {
                self.open_mode_picker();
                return;
            }
            (KeyCode::Left, _) if key.modifiers.contains(KeyModifiers::ALT) && (self.focus == Focus::Sidebar || self.editor().is_empty()) => {
                let cur = self.sidebar_width.unwrap_or(render::SIDEBAR_WIDTH);
                self.sidebar_width = Some(cur.saturating_sub(2).max(16));
                return;
            }
            (KeyCode::Right, _) if key.modifiers.contains(KeyModifiers::ALT) && (self.focus == Focus::Sidebar || self.editor().is_empty()) => {
                let cur = self.sidebar_width.unwrap_or(render::SIDEBAR_WIDTH);
                let total = self.areas.sidebar.width + self.areas.transcript.width;
                self.sidebar_width = Some((cur + 2).min(total.saturating_sub(render::MIN_MAIN_WIDTH)));
                return;
            }
            (KeyCode::PageUp, _) => {
                self.with_viewport(|v| v.page_up());
                return;
            }
            (KeyCode::PageDown, _) => {
                self.with_viewport(|v| v.page_down());
                return;
            }
            (KeyCode::Home, _) if self.editor().is_empty() && self.focus != Focus::Input => {
                self.with_viewport(|v| v.to_top());
                return;
            }
            (KeyCode::End, _) if self.editor().is_empty() => {
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
                    let line = std::mem::take(&mut self.command);
                    self.focus = Focus::Input;
                    if !line.trim().is_empty() {
                        self.run_command(&line);
                    }
                }
                // Backspace past the ':' returns to the message editor.
                KeyCode::Backspace if self.command.is_empty() => self.focus = Focus::Input,
                KeyCode::Backspace if key.modifiers.contains(KeyModifiers::ALT) => {
                    let trimmed = self.command.trim_end().to_owned();
                    let cut = trimmed.rfind(' ').map(|i| i + 1).unwrap_or(0);
                    self.command.truncate(cut);
                }
                KeyCode::Backspace => {
                    self.command.pop();
                }
                KeyCode::Char('u') if ctrl => self.command.clear(),
                KeyCode::Char('w') if ctrl => {
                    let trimmed = self.command.trim_end().to_owned();
                    let cut = trimmed.rfind(' ').map(|i| i + 1).unwrap_or(0);
                    self.command.truncate(cut);
                }
                KeyCode::Char('c') if ctrl => {
                    self.command.clear();
                    self.focus = Focus::Input;
                }
                KeyCode::Char(c) if !ctrl => self.command.push(c),
                _ => {}
            },
            Focus::Transcript => match key.code {
                KeyCode::Esc | KeyCode::Enter | KeyCode::Tab | KeyCode::Char('i') => self.focus = Focus::Input,
                KeyCode::Char('j') | KeyCode::Down => self.with_viewport(|v| v.scroll_by(1)),
                KeyCode::Char('k') | KeyCode::Up => self.with_viewport(|v| v.scroll_by(-1)),
                KeyCode::Char('d') => self.with_viewport(|v| v.page_down()),
                KeyCode::Char('u') => self.with_viewport(|v| v.page_up()),
                KeyCode::Char('g') | KeyCode::Home => self.with_viewport(|v| v.to_top()),
                KeyCode::Char('G') | KeyCode::End => self.with_viewport(|v| v.to_bottom()),
                KeyCode::Char(':') => self.focus = Focus::Command,
                KeyCode::Char('?') => self.overlay = Overlay::Help,
                KeyCode::Char('y') => self.answer_permission(PermChoice::Allow),
                KeyCode::Char('n') => self.answer_permission(PermChoice::Deny),
                KeyCode::Char('x') => self.cancel(),
                _ => {}
            },
            Focus::Sidebar => match key.code {
                KeyCode::Esc | KeyCode::Tab => self.focus = Focus::Input,
                KeyCode::Char('j') | KeyCode::Down => self.select(self.selected + 1),
                KeyCode::Char('k') | KeyCode::Up => self.select(self.selected.saturating_sub(1)),
                KeyCode::Enter => self.focus = Focus::Input,
                KeyCode::Char(':') => self.focus = Focus::Command,
                KeyCode::Char('?') => self.overlay = Overlay::Help,
                KeyCode::Char('n') => self.open_draft(),
                KeyCode::Char('x') => self.run_command("kill"),
                KeyCode::Char('X') => self.run_command("kill --purge"),
                KeyCode::Char('r') => {
                    self.command = "rename ".into();
                    self.focus = Focus::Command;
                }
                KeyCode::Char('f') => self.run_command("fork"),
                KeyCode::Char('m') => self.open_model_picker(),
                KeyCode::Char('o') => self.open_mode_picker(),
                KeyCode::Char('y') => self.answer_permission(PermChoice::Allow),
                KeyCode::Char('d') => self.answer_permission(PermChoice::Deny),
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
                            return self.answer_permission(PermChoice::Index(c as usize - '1' as usize));
                        }
                        _ => {}
                    }
                }
                let alt = key.modifiers.contains(KeyModifiers::ALT);
                let shift = key.modifiers.contains(KeyModifiers::SHIFT);
                match key.code {
                    KeyCode::Tab => self.focus = Focus::Sidebar,
                    KeyCode::Esc => {
                        if !self.editor().is_empty() {
                            self.editor_mut().clear();
                        } else if self.on_draft() {
                            self.discard_draft();
                        } else {
                            self.focus = Focus::Sidebar;
                        }
                    }
                    KeyCode::Char(':') if self.editor().is_empty() => self.focus = Focus::Command,
                    KeyCode::Char('?') if self.editor().is_empty() => self.overlay = Overlay::Help,
                    KeyCode::Char('s') if ctrl => self.send_prompt(true),
                    KeyCode::Enter if alt || shift => self.editor_mut().insert('\n'),
                    KeyCode::Char('j') if ctrl => self.editor_mut().insert('\n'),
                    KeyCode::Enter => {
                        if self.editor_mut().enter_means_newline() {
                            self.editor_mut().replace_trailing_backslash_with_newline();
                        } else {
                            self.send_prompt(false);
                        }
                    }
                    KeyCode::Backspace if alt => self.editor_mut().delete_word_back(),
                    KeyCode::Backspace => self.editor_mut().backspace(),
                    KeyCode::Delete => self.editor_mut().delete(),
                    KeyCode::Left if alt => self.editor_mut().word_left(),
                    KeyCode::Right if alt => self.editor_mut().word_right(),
                    KeyCode::Left => self.editor_mut().left(),
                    KeyCode::Right => self.editor_mut().right(),
                    KeyCode::Up => self.editor_mut().up(),
                    KeyCode::Down => self.editor_mut().down(),
                    KeyCode::Home => self.editor_mut().home(),
                    KeyCode::End => self.editor_mut().end(),
                    KeyCode::Char('a') if ctrl => self.editor_mut().home(),
                    KeyCode::Char('e') if ctrl => self.editor_mut().end(),
                    KeyCode::Char('b') if ctrl => self.editor_mut().left(),
                    KeyCode::Char('f') if ctrl => self.editor_mut().right(),
                    KeyCode::Char('b') if alt => self.editor_mut().word_left(),
                    KeyCode::Char('f') if alt => self.editor_mut().word_right(),
                    KeyCode::Char('d') if alt => self.editor_mut().delete_word_forward(),
                    KeyCode::Char('d') if ctrl => self.editor_mut().delete(),
                    KeyCode::Char('w') if ctrl => self.editor_mut().delete_word_back(),
                    KeyCode::Char('k') if ctrl => self.editor_mut().kill_to_line_end(),
                    KeyCode::Char('u') if ctrl => self.editor_mut().kill_to_line_start(),
                    KeyCode::Char('h') if ctrl => self.editor_mut().backspace(),
                    KeyCode::Char(c) if !ctrl && !alt => self.editor_mut().insert(c),
                    _ => {}
                }
            }
        }
    }

}
