//! Key combos: `"cmd+shift+t"`, `"Return"`, `"ctrl+alt+Delete"`. One
//! portable vocabulary; each desktop maps [`Key`] to its own codes.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum Modifier {
    Shift,
    Control,
    /// Option on macOS, Alt elsewhere.
    Alt,
    /// Command on macOS, the Windows key / Super elsewhere.
    Meta,
    Fn,
}

impl Modifier {
    fn parse(token: &str) -> Option<Self> {
        Some(match token {
            "shift" => Modifier::Shift,
            "ctrl" | "control" => Modifier::Control,
            "alt" | "option" | "opt" => Modifier::Alt,
            "cmd" | "command" | "meta" | "super" | "win" | "windows" => Modifier::Meta,
            "fn" => Modifier::Fn,
            _ => return None,
        })
    }
}

/// A named non-character key, or one character.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Key {
    Char(char),
    Return,
    Tab,
    Space,
    Backspace,
    Delete,
    Escape,
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    PageUp,
    PageDown,
    F(u8),
}

impl Key {
    fn parse(token: &str) -> Option<Self> {
        let lower = token.to_ascii_lowercase();
        Some(match lower.as_str() {
            "return" | "enter" => Key::Return,
            "tab" => Key::Tab,
            "space" => Key::Space,
            "backspace" => Key::Backspace,
            "delete" | "del" | "forwarddelete" => Key::Delete,
            "escape" | "esc" => Key::Escape,
            "left" | "arrowleft" => Key::Left,
            "right" | "arrowright" => Key::Right,
            "up" | "arrowup" => Key::Up,
            "down" | "arrowdown" => Key::Down,
            "home" => Key::Home,
            "end" => Key::End,
            "pageup" => Key::PageUp,
            "pagedown" => Key::PageDown,
            "plus" => Key::Char('+'),
            _ => {
                if let Some(n) = lower.strip_prefix('f').and_then(|n| n.parse::<u8>().ok())
                    && (1..=24).contains(&n)
                {
                    return Some(Key::F(n));
                }
                let mut chars = token.chars();
                let c = chars.next()?;
                if chars.next().is_some() {
                    return None;
                }
                Key::Char(c)
            }
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyCombo {
    pub modifiers: Vec<Modifier>,
    pub key: Key,
}

impl KeyCombo {
    /// Parses `"cmd+shift+t"`. A lone `"+"` is the plus key.
    pub fn parse(text: &str) -> Result<Self, String> {
        let text = text.trim();
        if text.is_empty() {
            return Err("empty key combo".into());
        }
        if text == "+" {
            return Ok(Self { modifiers: vec![], key: Key::Char('+') });
        }
        // "cmd++" is Command and the plus key.
        if let Some(head) = text.strip_suffix("++") {
            let mut modifiers = Self::parse_modifiers(
                &head.split('+').map(|t| t.trim().to_string()).collect::<Vec<_>>(),
            )
            .map_err(|e| format!("{e} in {text:?}"))?;
            modifiers.sort();
            return Ok(Self { modifiers, key: Key::Char('+') });
        }
        let tokens: Vec<&str> = text.split('+').map(str::trim).collect();
        let (last, mods) = tokens.split_last().ok_or("empty key combo")?;
        let mut modifiers = Vec::new();
        for token in mods {
            let m = Modifier::parse(&token.to_ascii_lowercase())
                .ok_or_else(|| format!("unknown modifier {token:?} in {text:?}"))?;
            if !modifiers.contains(&m) {
                modifiers.push(m);
            }
        }
        modifiers.sort();
        let key = Key::parse(last).ok_or_else(|| format!("unknown key {last:?} in {text:?}"))?;
        Ok(Self { modifiers, key })
    }

    pub fn parse_modifiers(list: &[String]) -> Result<Vec<Modifier>, String> {
        let mut out = Vec::new();
        for token in list {
            let m = Modifier::parse(&token.to_ascii_lowercase())
                .ok_or_else(|| format!("unknown modifier {token:?}"))?;
            if !out.contains(&m) {
                out.push(m);
            }
        }
        out.sort();
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_trailing_double_plus_is_the_plus_key() {
        let c = KeyCombo::parse("cmd++").unwrap();
        assert_eq!((c.modifiers.clone(), c.key), (vec![Modifier::Meta], Key::Char('+')));
        let c = KeyCombo::parse("ctrl+shift++").unwrap();
        assert_eq!(c.key, Key::Char('+'));
        assert_eq!(c.modifiers.len(), 2);
        assert!(KeyCombo::parse("nope++").is_err());
    }

    use super::*;

    #[test]
    fn parses_combos() {
        let c = KeyCombo::parse("cmd+shift+t").unwrap();
        assert_eq!(c.modifiers, vec![Modifier::Shift, Modifier::Meta]);
        assert_eq!(c.key, Key::Char('t'));
        assert_eq!(KeyCombo::parse("Return").unwrap().key, Key::Return);
        assert_eq!(KeyCombo::parse("ctrl+F5").unwrap().key, Key::F(5));
        assert_eq!(KeyCombo::parse("+").unwrap().key, Key::Char('+'));
        assert_eq!(KeyCombo::parse("cmd+plus").unwrap().key, Key::Char('+'));
        assert!(KeyCombo::parse("hyper+x").is_err());
        assert!(KeyCombo::parse("cmd+notakey").is_err());
    }
}
