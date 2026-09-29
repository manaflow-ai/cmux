//! Configurable app shortcuts. A sequence is space-separated; commas are alternatives.
use super::*;
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq)]
struct Stroke { code: KeyCode, mods: KeyModifiers }
impl Stroke {
    fn event(k: KeyEvent) -> Self {
        let mut code = k.code;
        let mods = k.modifiers & (KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER | KeyModifiers::SHIFT);
        if let KeyCode::Char(c) = code && c.is_ascii_alphabetic() { code = KeyCode::Char(c.to_ascii_lowercase()); }
        Self { code, mods }
    }
    fn parse(s: &str) -> Result<Self> {
        let s = s.to_ascii_lowercase();
        let mut parts: Vec<_> = s.split('+').collect();
        let name = parts.pop().unwrap_or("");
        let mut mods = KeyModifiers::NONE;
        for p in parts { mods |= match p { "ctrl" | "control" => KeyModifiers::CONTROL, "alt" | "option" | "opt" => KeyModifiers::ALT, "cmd" | "super" | "meta" => KeyModifiers::SUPER, "shift" => KeyModifiers::SHIFT, _ => anyhow::bail!("unknown key modifier {p:?}") }; }
        let code = match name {
            "space" => KeyCode::Char(' '), "enter" | "return" => KeyCode::Enter, "esc" | "escape" => KeyCode::Esc,
            "tab" if mods.contains(KeyModifiers::SHIFT) => KeyCode::BackTab, "tab" => KeyCode::Tab,
            "up" => KeyCode::Up, "down" => KeyCode::Down, "left" => KeyCode::Left, "right" => KeyCode::Right,
            "pageup" | "pgup" => KeyCode::PageUp, "pagedown" | "pgdown" => KeyCode::PageDown,
            "home" => KeyCode::Home, "end" => KeyCode::End, "backspace" => KeyCode::Backspace, "delete" => KeyCode::Delete,
            s if s.starts_with('f') && s[1..].parse::<u8>().is_ok() => KeyCode::F(s[1..].parse()?),
            s if s.chars().count() == 1 => KeyCode::Char(s.chars().next().unwrap()),
            _ => anyhow::bail!("unknown key {name:?}"),
        };
        Ok(Self { code, mods })
    }
}

#[derive(Debug, Clone)]
struct Binding { keys: Vec<Stroke>, command: String, label: String }
#[derive(Default)]
pub struct Keymap { bindings: Vec<Binding>, pending: Vec<Stroke>, at: Option<Instant>, timeout_ms: u64 }
#[derive(Debug, PartialEq)]
pub enum Match { Pass, Pending(String), Run(String), Cancelled }

fn command_id(id: &str) -> &str {
    match id {
        "command_list" => "palette", "session_new" => "new", "session_list" => "sessions", "model_list" => "model",
        "agent_list" => "mode", "sidebar_toggle" => "toggle-sidebar", "app_exit" => "quit", "help_show" => "help",
        "session_interrupt" => "cancel", "prompt_skills" => "skills", "variant_list" => "effort", "workspace_set" => "cwd",
        "messages_page_up" => "pageup", "messages_page_down" => "pagedown", "messages_first" => "top", "messages_last" => "bottom",
        "display_thinking" => "thoughts", "input_undo" => "undo", other => other,
    }
}
impl Keymap {
    pub fn new(cfg: &crate::config::TuiConfig) -> Result<Self> {
        let mut specs: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for (id, keys) in [
            ("palette", "ctrl+shift+p,super+shift+p,super+k,<leader>p"), ("new", "ctrl+t,alt+n,<leader>n"),
            ("sessions", "<leader>l"), ("model", "ctrl+l,alt+m,<leader>m"), ("mode", "ctrl+o,<leader>a"),
            ("effort", "alt+e"), ("policy", "alt+p"), ("cwd", "alt+shift+d,<leader>d"),
            ("skills", "<leader>k"), ("quit", "ctrl+q,<leader>q"), ("help", "<leader>h"),
            ("toggle-sidebar", "alt+s,<leader>b"), ("next", "alt+]"), ("prev", "alt+["), ("cancel", "ctrl+g"),
            ("focus-sidebar", "alt+h,super+ctrl+h"), ("focus-content", "alt+l,super+ctrl+l"),
            ("focus-transcript", "alt+k,super+ctrl+k"), ("focus-composer", "alt+j,super+ctrl+j"),
            ("pageup", "pageup"), ("pagedown", "pagedown"), ("steer", "ctrl+s"), ("undo", "ctrl+z"),
        ] { specs.insert(actions::find(id).map(|d| d.name).unwrap_or(id).into(), keys.split(',').map(str::to_owned).collect()); }
        for n in 1..=9 { specs.insert(format!("session-{n}"), vec![format!("alt+{n}")]); }
        let leader = match cfg.keybinds.get("leader") {
            Some(Value::Bool(false)) => "none",
            Some(Value::String(s)) => s,
            None => &cfg.leader,
            _ => anyhow::bail!("keybind leader must be a key string or false"),
        };
        anyhow::ensure!((100..=60_000).contains(&cfg.leader_timeout_ms), "leaderTimeoutMs must be between 100 and 60000");
        for (id, value) in &cfg.keybinds {
            if id == "leader" { continue; }
            let id = command_id(id);
            let id = actions::find(id).map(|d| d.name).unwrap_or(id);
            if !id.strip_prefix("session-").and_then(|s| s.parse::<usize>().ok()).map(|n| (1..=9).contains(&n)).unwrap_or(false) && actions::find(id).is_none() { anyhow::bail!("unknown acpmux keybind action {id:?}"); }
            let values: Vec<String> = match value {
                Value::Bool(false) | Value::Null => vec![],
                Value::String(s) if s == "none" => vec![],
                Value::String(s) => s.split(',').map(|s| s.trim().to_owned()).collect(),
                Value::Array(a) => a.iter().map(|v| v.as_str().map(str::to_owned).ok_or_else(|| anyhow::anyhow!("keybind {id} expects an array of strings"))).collect::<Result<_>>()?,
                _ => anyhow::bail!("keybind {id} expects a string, array, or false"),
            };
            specs.insert(id.into(), values);
        }
        let mut out = Self { timeout_ms: cfg.leader_timeout_ms, ..Self::default() };
        for (command, variants) in specs {
            for label in variants {
                if label.is_empty() || label == "none" { continue; }
                if label.contains("<leader>") && (leader == "none" || leader.is_empty()) { continue; }
                let expanded = label.replace("<leader>", &format!("{leader} "));
                let keys = expanded.split_whitespace().map(Stroke::parse).collect::<Result<Vec<_>>>()?;
                if keys.is_empty() { continue; }
                out.bindings.push(Binding { keys, command: command.clone(), label: expanded.split_whitespace().collect::<Vec<_>>().join(" then ") });
            }
        }
        for (i, a) in out.bindings.iter().enumerate() { for b in &out.bindings[i+1..] {
            if a.keys.starts_with(&b.keys) || b.keys.starts_with(&a.keys) { anyhow::bail!("conflicting shortcuts: {} ({}) and {} ({})", a.label, a.command, b.label, b.command); }
        } }
        Ok(out)
    }
    pub fn hints(&self, command: &str) -> String {
        self.bindings.iter().filter(|b| b.command == command || actions::find(&b.command).zip(actions::find(command)).map(|(a,b)| a.action == b.action).unwrap_or(false)).map(|b| b.label.as_str()).collect::<Vec<_>>().join(" / ")
    }
    pub fn expire(&mut self) -> bool {
        if self.at.map(|t| t.elapsed().as_millis() >= self.timeout_ms as u128).unwrap_or(false) { self.clear(); true } else { false }
    }
    pub fn clear(&mut self) { self.pending.clear(); self.at = None; }
    pub fn feed(&mut self, key: KeyEvent) -> Match {
        self.expire();
        if !self.pending.is_empty() && key.code == KeyCode::Esc { self.clear(); return Match::Cancelled; }
        let was_pending = !self.pending.is_empty();
        self.pending.push(Stroke::event(key));
        if let Some(b) = self.bindings.iter().find(|b| b.keys == self.pending) { let cmd = b.command.clone(); self.clear(); return Match::Run(cmd); }
        let next: Vec<_> = self.bindings.iter().filter(|b| b.keys.starts_with(&self.pending)).map(|b| format!("{}: {}", b.label, b.command)).collect();
        if !next.is_empty() { self.at = Some(Instant::now()); return Match::Pending(next.join(" · ")); }
        self.clear();
        if was_pending { Match::Cancelled } else { Match::Pass }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn leader_is_sequential_cancellable_and_modifier_exact() {
        let mut map = Keymap::new(&crate::config::TuiConfig::default()).unwrap();
        assert!(matches!(map.feed(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::CONTROL)), Match::Pending(_)));
        assert_eq!(map.feed(KeyEvent::new(KeyCode::Char('p'), KeyModifiers::NONE)), Match::Run("palette".into()));
        map.feed(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::CONTROL));
        assert_eq!(map.feed(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE)), Match::Cancelled);
        assert_eq!(map.feed(KeyEvent::new(KeyCode::Char('d'), KeyModifiers::ALT)), Match::Pass);
        assert_eq!(map.feed(KeyEvent::new(KeyCode::Char('k'), KeyModifiers::SUPER)), Match::Run("palette".into()));
    }
    #[test]
    fn overrides_disable_old_keys_and_accept_long_chords() {
        let cfg: crate::config::TuiConfig = serde_json::from_value(json!({"leader":"ctrl+space", "keybinds":{"session_new":["<leader>g n"],"model_list":false,"command_list":"ctrl+p"}})).unwrap();
        let mut m = Keymap::new(&cfg).unwrap();
        assert_eq!(m.feed(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::ALT)), Match::Pass);
        assert_eq!(m.feed(KeyEvent::new(KeyCode::Char('m'), KeyModifiers::ALT)), Match::Pass);
        assert!(matches!(m.feed(KeyEvent::new(KeyCode::Char(' '), KeyModifiers::CONTROL)), Match::Pending(_)));
        assert!(matches!(m.feed(KeyEvent::new(KeyCode::Char('g'), KeyModifiers::NONE)), Match::Pending(_)));
        assert_eq!(m.feed(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::NONE)), Match::Run("new".into()));
        m.feed(KeyEvent::new(KeyCode::Char(' '), KeyModifiers::CONTROL));
        m.at = Some(Instant::now() - std::time::Duration::from_secs(3));
        assert_eq!(m.feed(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::NONE)), Match::Pass);
    }
}
