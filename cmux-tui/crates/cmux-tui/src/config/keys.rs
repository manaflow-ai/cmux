//! Key bindings: chords, their parsing and normalization, and the configurable Keys table with its defaults.

use super::*;

/// A key chord: code plus required modifiers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Chord {
    pub code: KeyCode,
    pub mods: KeyModifiers,
}

pub(super) fn normalize_chord(code: KeyCode, mut mods: KeyModifiers) -> (KeyCode, KeyModifiers) {
    match code {
        KeyCode::Tab if mods.contains(KeyModifiers::SHIFT) => {
            mods.remove(KeyModifiers::SHIFT);
            (KeyCode::BackTab, mods)
        }
        KeyCode::Char(c) if mods.contains(KeyModifiers::SHIFT) => {
            let Some(shifted) = crate::keys::shifted_ascii_char(c) else {
                return (code, mods);
            };
            mods.remove(KeyModifiers::SHIFT);
            (KeyCode::Char(shifted), mods)
        }
        KeyCode::BackTab => {
            // Crossterm reports BackTab with an implied Shift modifier.
            mods.remove(KeyModifiers::SHIFT);
            (KeyCode::BackTab, mods)
        }
        _ => (code, mods),
    }
}

pub(super) fn canonical_chord(chord: Chord) -> Chord {
    const TRACKED: KeyModifiers = KeyModifiers::CONTROL
        .union(KeyModifiers::ALT)
        .union(KeyModifiers::SHIFT)
        .union(KeyModifiers::SUPER)
        .union(KeyModifiers::HYPER)
        .union(KeyModifiers::META);
    let (code, mods) = normalize_chord(chord.code, chord.mods);
    Chord { code, mods: mods & TRACKED }
}

impl Chord {
    pub fn matches(&self, key: &KeyEvent) -> bool {
        canonical_chord(*self) == canonical_chord(Chord { code: key.code, mods: key.modifiers })
    }

    /// Human-readable form used beside context-menu actions. Keep this
    /// derived from the resolved chord so config overrides teach the keys
    /// that are actually active.
    pub fn display_label(&self) -> Option<String> {
        let mut modifiers = Vec::new();
        if self.mods.contains(KeyModifiers::CONTROL) {
            modifiers.push("Ctrl");
        }
        if self.mods.contains(KeyModifiers::ALT) {
            modifiers.push("Alt");
        }
        if self.mods.contains(KeyModifiers::SHIFT) {
            modifiers.push("Shift");
        }
        if self.mods.contains(KeyModifiers::SUPER) {
            modifiers.push("Super");
        }
        let key = match self.code {
            KeyCode::Char(' ') => "Space".to_string(),
            KeyCode::Char(character) => character.to_string(),
            KeyCode::Tab => "Tab".to_string(),
            KeyCode::BackTab => "BackTab".to_string(),
            KeyCode::Enter => "Enter".to_string(),
            KeyCode::Esc => "Esc".to_string(),
            KeyCode::Left => "Left".to_string(),
            KeyCode::Right => "Right".to_string(),
            KeyCode::Up => "Up".to_string(),
            KeyCode::Down => "Down".to_string(),
            KeyCode::PageUp => "PageUp".to_string(),
            KeyCode::PageDown => "PageDown".to_string(),
            KeyCode::Home => "Home".to_string(),
            KeyCode::End => "End".to_string(),
            _ => return None,
        };
        if modifiers.is_empty() {
            Some(key)
        } else {
            Some(format!("{}-{key}", modifiers.join("-")))
        }
    }
}

/// Resolved key bindings: the prefix chord plus one chord per action.
#[derive(Debug, Clone)]
pub struct Keys {
    pub prefix: Chord,
    /// Resolve empty-text Alt character events using the host terminal's
    /// macOS Option mode instead of guessing from each event.
    pub macos_option_as_alt: bool,
    pub(super) bindings: Vec<(Chord, Action)>,
    action_by_chord: HashMap<Chord, Action>,
    modeless_action_by_chord: HashMap<Chord, Action>,
    pub(crate) provider_menu_overridden: bool,
}

impl Default for Keys {
    fn default() -> Self {
        let bind = |code, action| (Chord { code, mods: KeyModifiers::NONE }, action);
        let alt = |code, action| (Chord { code, mods: KeyModifiers::ALT }, action);
        let command = |code, action| (Chord { code, mods: KeyModifiers::SUPER }, action);
        let prefix = Chord { code: KeyCode::Char('b'), mods: KeyModifiers::CONTROL };
        let mut keys = Keys {
            prefix,
            macos_option_as_alt: true,
            bindings: vec![
                (prefix, Action::SendPrefix),
                bind(KeyCode::Char('t'), Action::NewTab),
                alt(KeyCode::Char('t'), Action::NewTab),
                bind(KeyCode::Char('B'), Action::NewBrowserTab),
                alt(KeyCode::Char('n'), Action::NewPaneSmart),
                bind(KeyCode::Char('N'), Action::NewPaneSmart),
                bind(KeyCode::Tab, Action::NextTab),
                bind(KeyCode::BackTab, Action::PrevTab),
                bind(KeyCode::Char('%'), Action::SplitRight),
                bind(KeyCode::Char('"'), Action::SplitDown),
                bind(KeyCode::Char('x'), Action::CloseTab),
                bind(KeyCode::Char('X'), Action::ClosePane),
                bind(KeyCode::Char(','), Action::RenameScreen),
                bind(KeyCode::Char('$'), Action::RenameWorkspace),
                bind(KeyCode::Char('&'), Action::CloseScreen),
                bind(KeyCode::Char('p'), Action::PrevScreen),
                alt(KeyCode::Char('['), Action::PrevScreen),
                bind(KeyCode::Char('n'), Action::NextScreen),
                alt(KeyCode::Char(']'), Action::NextScreen),
                bind(KeyCode::Char('1'), Action::select_screen(1).unwrap()),
                bind(KeyCode::Char('2'), Action::select_screen(2).unwrap()),
                bind(KeyCode::Char('3'), Action::select_screen(3).unwrap()),
                bind(KeyCode::Char('4'), Action::select_screen(4).unwrap()),
                bind(KeyCode::Char('5'), Action::select_screen(5).unwrap()),
                bind(KeyCode::Char('6'), Action::select_screen(6).unwrap()),
                bind(KeyCode::Char('7'), Action::select_screen(7).unwrap()),
                bind(KeyCode::Char('8'), Action::select_screen(8).unwrap()),
                bind(KeyCode::Char('9'), Action::select_screen(9).unwrap()),
                bind(KeyCode::Char('0'), Action::select_screen(0).unwrap()),
                bind(KeyCode::Char('c'), Action::NewScreen),
                bind(KeyCode::Char('('), Action::PrevWorkspace),
                alt(KeyCode::Char('{'), Action::PrevWorkspace),
                bind(KeyCode::Char('w'), Action::NextWorkspace),
                bind(KeyCode::Char(')'), Action::NextWorkspace),
                alt(KeyCode::Char('}'), Action::NextWorkspace),
                bind(KeyCode::Char('W'), Action::NewWorkspace),
                bind(KeyCode::Char('D'), Action::CloseWorkspace),
                bind(KeyCode::Char('s'), Action::ToggleSidebar),
                bind(KeyCode::Char('m'), Action::ToggleSidebarCompact),
                bind(KeyCode::Char('e'), Action::ToggleSidebarView),
                bind(KeyCode::Char('S'), Action::FocusSidebar),
                bind(KeyCode::Char('g'), Action::NewPaneRight),
                bind(KeyCode::Char('U'), Action::UndoLayout),
                bind(KeyCode::Char('o'), Action::FocusNextPane),
                bind(KeyCode::Char('h'), Action::FocusLeft),
                bind(KeyCode::Left, Action::FocusLeft),
                alt(KeyCode::Char('h'), Action::FocusLeft),
                alt(KeyCode::Left, Action::FocusLeft),
                bind(KeyCode::Char('l'), Action::FocusRight),
                bind(KeyCode::Right, Action::FocusRight),
                alt(KeyCode::Char('l'), Action::FocusRight),
                alt(KeyCode::Right, Action::FocusRight),
                bind(KeyCode::Char('k'), Action::FocusUp),
                bind(KeyCode::Up, Action::FocusUp),
                alt(KeyCode::Char('k'), Action::FocusUp),
                alt(KeyCode::Up, Action::FocusUp),
                bind(KeyCode::Char('j'), Action::FocusDown),
                bind(KeyCode::Down, Action::FocusDown),
                alt(KeyCode::Char('j'), Action::FocusDown),
                alt(KeyCode::Down, Action::FocusDown),
                alt(KeyCode::Char('='), Action::ResizeGrow),
                bind(KeyCode::Char('+'), Action::ResizeGrow),
                alt(KeyCode::Char('-'), Action::ResizeShrink),
                bind(KeyCode::Char('-'), Action::ResizeShrink),
                bind(KeyCode::Char('z'), Action::ZoomPane),
                bind(KeyCode::Char('{'), Action::SwapPanePrev),
                bind(KeyCode::Char('}'), Action::SwapPaneNext),
                bind(KeyCode::Char('['), Action::ScrollUp),
                bind(KeyCode::PageUp, Action::ScrollUp),
                bind(KeyCode::PageDown, Action::ScrollDown),
                command(KeyCode::Char('k'), Action::ClearHistory),
                bind(KeyCode::Char('<'), Action::BrowserBack),
                bind(KeyCode::Char('>'), Action::BrowserForward),
                bind(KeyCode::Char('r'), Action::BrowserReload),
                bind(KeyCode::Char('u'), Action::BrowserEditUrl),
                bind(KeyCode::Char('?'), Action::ShowShortcuts),
                bind(KeyCode::Char('d'), Action::Detach),
            ],
            action_by_chord: HashMap::new(),
            modeless_action_by_chord: HashMap::new(),
            provider_menu_overridden: false,
        };
        keys.rebuild_dispatch_maps();
        keys
    }
}

impl Keys {
    pub(super) fn rebuild_dispatch_maps(&mut self) {
        self.action_by_chord.clear();
        self.modeless_action_by_chord.clear();
        for &(chord, action) in &self.bindings {
            let canonical = canonical_chord(chord);
            // Keep the first binding in canonical order. Config mutation
            // resolves intentional collisions before this cache is built.
            self.action_by_chord.entry(canonical).or_insert(action);
            if self.is_modeless_binding(&chord, action) {
                self.modeless_action_by_chord.entry(canonical).or_insert(action);
            }
        }
    }

    fn is_modeless_binding(&self, chord: &Chord, action: Action) -> bool {
        if action == Action::SendPrefix && *chord == self.prefix {
            return false;
        }
        chord.mods.intersects(KeyModifiers::ALT | KeyModifiers::SUPER)
            || (action == Action::ClearHistory && chord.mods.contains(KeyModifiers::CONTROL))
    }

    fn shortcut_label_for_chord(&self, action: Action, chord: &Chord) -> Option<String> {
        let chord_label = chord.display_label()?;
        if self.is_modeless_binding(chord, action) {
            Some(chord_label)
        } else {
            Some(format!("{} {chord_label}", self.prefix.display_label()?))
        }
    }

    /// The action bound to a key event (after the prefix).
    pub fn action_for(&self, key: &KeyEvent) -> Option<Action> {
        self.action_by_chord
            .get(&canonical_chord(Chord { code: key.code, mods: key.modifiers }))
            .copied()
    }

    /// The modeless action bound to a key event. Alt- and Super-modified
    /// chords are modeless, as are Control-modified clear-history chords;
    /// other chords remain prefix-only.
    pub fn modeless_action_for(&self, key: &KeyEvent) -> Option<Action> {
        self.modeless_action_by_chord
            .get(&canonical_chord(Chord { code: key.code, mods: key.modifiers }))
            .copied()
    }

    /// The first configured shortcut for an action, including the prefix
    /// for prefix-only chords. Returns `None` when the action is unbound.
    pub fn shortcut_label(&self, action: Action) -> Option<String> {
        self.shortcut_labels(action).into_iter().next()
    }

    /// Every configured shortcut for an action. Prefix-only chords include
    /// the resolved prefix, while Alt chords are shown as modeless shortcuts.
    pub fn shortcut_labels(&self, action: Action) -> Vec<String> {
        self.bindings
            .iter()
            .filter(|(_, bound)| *bound == action)
            .filter_map(|(chord, _)| self.shortcut_label_for_chord(action, chord))
            .collect()
    }

    /// The first suffix key that invokes an action after the prefix. Used by
    /// the prefix help bar, which must not advertise modeless-only bindings.
    pub fn prefixed_key_label(&self, action: Action) -> Option<String> {
        self.bindings
            .iter()
            .find(|(chord, bound)| *bound == action && !self.is_modeless_binding(chord, action))
            .and_then(|(chord, _)| chord.display_label())
    }

    /// Bound actions in canonical catalog order, ready for shortcut help and
    /// future command surfaces.
    pub fn resolved_shortcuts(&self) -> Vec<(&'static ActionDefinition, Vec<String>)> {
        let mut shortcuts_by_action = HashMap::<Action, Vec<String>>::new();
        for (chord, action) in &self.bindings {
            if let Some(label) = self.shortcut_label_for_chord(*action, chord) {
                shortcuts_by_action.entry(*action).or_default().push(label);
            }
        }
        action_definitions()
            .iter()
            .copied()
            .filter_map(|definition| {
                shortcuts_by_action
                    .remove(&definition.action)
                    .filter(|shortcuts| !shortcuts.is_empty())
                    .map(|shortcuts| (definition, shortcuts))
            })
            .collect()
    }

    /// Bind one user-command chord, stealing the chord from any action or
    /// earlier command that held it. The prefix chord stays reserved.
    /// Returns whether the chord was bound.
    pub(super) fn bind_user_command_chord(
        &mut self,
        id: &str,
        action: Action,
        chord: Chord,
    ) -> bool {
        if chord == self.prefix {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring command binding {id:?} because it conflicts with the prefix"
            );
            return false;
        }
        self.bindings.retain(|(existing, _)| existing != &chord);
        self.bindings.push((chord, action));
        true
    }

    /// Apply config overrides: `"prefix"` rebinds the prefix; any action
    /// name rebinds that action (replacing ALL default chords for it).
    pub(super) fn apply(&mut self, raw: &HashMap<String, Value>) {
        if let Some(value) = raw.get("macos_option_as_alt") {
            if let Some(value) = value.as_bool() {
                self.macos_option_as_alt = value;
            } else {
                let value = format!("{value:?}");
                crate::client_log::stderr_log!(
                    "config",
                    "{}",
                    catalog().config.invalid_macos_option_as_alt(&value)
                );
            }
        }
        if raw.get("alt_shortcuts").and_then(Value::as_bool) == Some(false) {
            self.bindings.retain(|(chord, _)| !chord.mods.contains(KeyModifiers::ALT));
        }
        if raw.get("super_shortcuts").and_then(Value::as_bool) == Some(false) {
            self.bindings.retain(|(chord, _)| !chord.mods.contains(KeyModifiers::SUPER));
        }
        if let Some(value) = raw.get("prefix") {
            if let Some(value) = value.as_str()
                && let Some(chord) = parse_chord(value)
            {
                let previous_prefix = self.prefix;
                self.prefix = chord;
                if !raw.contains_key(Action::SendPrefix.definition().config_key)
                    && let Some((send_prefix, _)) =
                        self.bindings.iter_mut().find(|(binding, action)| {
                            *action == Action::SendPrefix && *binding == previous_prefix
                        })
                {
                    *send_prefix = chord;
                }
            } else if value.as_str().is_some() {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring unparseable key binding prefix = {value:?}"
                );
            } else {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring non-string prefix binding {value:?}"
                );
            }
        }
        for (name, value) in raw {
            if name == "macos_option_as_alt"
                || name == "alt_shortcuts"
                || name == "super_shortcuts"
                || name == "prefix"
            {
                continue;
            }
            // The numbered families accept both spellings: select-screen-N /
            // select_screen_N and select-tab-N / select_tab_N.
            let normalized =
                if name.starts_with("select_screen_") || name.starts_with("select_tab_") {
                    name.replace('_', "-")
                } else {
                    name.clone()
                };
            match action_definitions().iter().find(|definition| {
                definition.config_key == normalized.as_str()
                    || (definition.action == Action::RenameTab && name == "rename-pane")
                    || (definition.action == Action::NewBrowserTab && name == "new_browser_tab")
            }) {
                Some(definition) => {
                    self.bindings.retain(|(_, action)| *action != definition.action);
                    let mut provider_menu_override_valid = definition.action
                        == Action::ProviderMenu
                        && matches!(value, Value::Array(values) if values.is_empty());
                    for raw_chord in key_values(value) {
                        if raw_chord.eq_ignore_ascii_case("none") {
                            if definition.action == Action::ProviderMenu {
                                provider_menu_override_valid = true;
                            }
                            continue;
                        }
                        let Some(chord) = parse_chord(raw_chord) else {
                            crate::client_log::stderr_log!(
                                "config",
                                "{BIN}: ignoring unparseable key binding {name} = {raw_chord:?}"
                            );
                            continue;
                        };
                        if chord == self.prefix && definition.action != Action::SendPrefix {
                            crate::client_log::stderr_log!(
                                "config",
                                "{BIN}: ignoring key binding {name} = {raw_chord:?} because it conflicts with the prefix"
                            );
                            continue;
                        }
                        if definition.action == Action::ProviderMenu {
                            provider_menu_override_valid = true;
                        }
                        self.bindings.retain(|(existing, _)| existing != &chord);
                        self.bindings.push((chord, definition.action));
                    }
                    if definition.action == Action::ProviderMenu {
                        self.provider_menu_overridden = provider_menu_override_valid;
                    }
                }
                None => crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring unknown key action {name:?}"
                ),
            }
        }
        let prefix = self.prefix;
        self.bindings.retain(|(chord, action)| *action == Action::SendPrefix || *chord != prefix);
        self.rebuild_dispatch_maps();
    }

    #[cfg(test)]
    pub(crate) fn apply_for_test(&mut self, raw: &HashMap<String, Value>) {
        self.apply(raw);
    }
}

pub(super) fn key_values(value: &Value) -> Vec<&str> {
    match value {
        Value::String(s) => vec![s.as_str()],
        Value::Array(values) => values.iter().filter_map(Value::as_str).collect(),
        _ => Vec::new(),
    }
}

/// Parse "c", "%", "ctrl+b", "alt+enter", "tab", "pageup", ...
pub(super) fn parse_chord(s: &str) -> Option<Chord> {
    let mut mods = KeyModifiers::NONE;
    let mut code = None;
    for part in s.split('+') {
        let part = part.trim();
        match part.to_lowercase().as_str() {
            "ctrl" | "control" => mods |= KeyModifiers::CONTROL,
            "alt" | "option" => mods |= KeyModifiers::ALT,
            "cmd" | "command" | "super" => mods |= KeyModifiers::SUPER,
            "shift" => mods |= KeyModifiers::SHIFT,
            "tab" => code = Some(KeyCode::Tab),
            "backtab" => code = Some(KeyCode::BackTab),
            "enter" | "return" => code = Some(KeyCode::Enter),
            "esc" | "escape" => code = Some(KeyCode::Esc),
            "space" => code = Some(KeyCode::Char(' ')),
            "left" => code = Some(KeyCode::Left),
            "right" => code = Some(KeyCode::Right),
            "up" => code = Some(KeyCode::Up),
            "down" => code = Some(KeyCode::Down),
            "pageup" => code = Some(KeyCode::PageUp),
            "pagedown" => code = Some(KeyCode::PageDown),
            "home" => code = Some(KeyCode::Home),
            "end" => code = Some(KeyCode::End),
            _ => {
                // Single character, case-sensitive (uppercase = shifted).
                let mut chars = part.chars();
                let c = chars.next()?;
                if chars.next().is_some() {
                    return None;
                }
                code = Some(KeyCode::Char(c));
            }
        }
    }

    let code = code?;
    // Store a shifted ASCII result so `D` and `shift+d` stay equivalent.
    // Shift stays explicit when the character itself cannot represent it.
    let (code, mods) = normalize_chord(code, mods);
    Some(Chord { code, mods })
}
