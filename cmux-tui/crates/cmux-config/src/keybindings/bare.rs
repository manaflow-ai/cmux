//! Bare first strokes (no cmd, ctrl or opt: `g g`, `] f`) in keybindings.json
//! (K1, plans/cmux-next/customization.md). Only pages that own bare keys (the
//! diff viewer, a read-only markdown page) take them; everywhere else a bare
//! key is typing. An entry whose first stroke is bare binds only when its
//! `when` requires one of [`OWNER_KEYS`] as an `&&` term and none of
//! [`TEXT_KEYS`]; a top-level `||` proves nothing, so it is refused. The app's
//! loader applies the same rule (`BareKeys` in CmuxNextActions), and
//! `schemas/keybindings/keybinding-vectors.json` pins both.
//!
//! The `when` grammar is the app's (`WhenClauseParser`): `!`, `&&`, `||`,
//! `==`, `!=`, `=~ /regex/`, `in`, `not in`, parentheses, `true`, `false`,
//! context keys and quoted or bare values. This reader only finds the
//! context keys a clause requires; the app still parses and evaluates it.

/// Context keys whose page owns bare keys (`ActionContext.bareKeyOwners`).
pub const OWNER_KEYS: &[&str] = &["diffViewerFocused", "markdownReadOnlyFocused"];

/// Context keys that can hold while a text field has the keyboard.
pub const TEXT_KEYS: &[&str] = &[
    "textInputFocus",
    "textBoxFocused",
    "omnibarFocused",
    "terminalFocused",
    "agentPaneFocused",
    "codeEditorFocused",
    "markdownEditorFocused",
    "browserFocused",
];

/// Whether a normalized stroke has none of cmd, ctrl and opt (shift is part
/// of the key).
pub fn is_bare(stroke: &str) -> bool {
    !stroke.split('+').any(|part| matches!(part, "cmd" | "ctrl" | "opt"))
}

/// Whether an entry whose first stroke is bare may bind under `when`.
pub fn may_bind(when: Option<&str>) -> bool {
    let Some(clause) = when.and_then(parse) else {
        return false;
    };
    let mut required = Vec::new();
    clause.required_keys(&mut required);
    required.iter().any(|key| OWNER_KEYS.contains(key))
        && !required.iter().any(|key| TEXT_KEYS.contains(key))
}

/// What this reader keeps of a parsed clause.
enum Clause {
    /// The key is set and truthy.
    Has(String),
    And(Vec<Clause>),
    /// Anything else (`||`, `!`, comparisons, constants): requires no key.
    Other,
}

impl Clause {
    /// The keys every `&&` term of the clause requires.
    fn required_keys<'a>(&'a self, out: &mut Vec<&'a str>) {
        match self {
            Clause::Has(key) => out.push(key),
            Clause::And(clauses) => clauses.iter().for_each(|clause| clause.required_keys(out)),
            Clause::Other => {}
        }
    }
}

/// `text` as a clause, or `None` when it does not parse.
fn parse(text: &str) -> Option<Clause> {
    let mut parser = Parser { bytes: text.as_bytes(), index: 0 };
    let clause = parser.or()?;
    parser.skip_space();
    (parser.index >= parser.bytes.len()).then_some(clause)
}

struct Parser<'a> {
    bytes: &'a [u8],
    index: usize,
}

/// Context key bytes: letters, digits, `.`, `_`, `-`, `:`.
fn is_word_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b':')
}

/// Bare value bytes: key bytes plus `/`, `@`, `+`, `#`.
fn is_value_byte(byte: u8) -> bool {
    is_word_byte(byte) || matches!(byte, b'/' | b'@' | b'+' | b'#')
}

impl Parser<'_> {
    fn peek(&self, offset: usize) -> Option<u8> {
        self.bytes.get(self.index + offset).copied()
    }

    fn skip_space(&mut self) {
        while matches!(self.peek(0), Some(b' ' | b'\t')) {
            self.index += 1;
        }
    }

    fn take(&mut self, token: &str) -> bool {
        self.skip_space();
        if self.bytes[self.index..].starts_with(token.as_bytes()) {
            self.index += token.len();
            true
        } else {
            false
        }
    }

    /// A keyword followed by a non-word byte (`in` must not eat `inbox`).
    fn take_word(&mut self, word: &str) -> bool {
        let start = self.index;
        if !self.take(word) {
            return false;
        }
        if self.peek(0).is_some_and(is_word_byte) {
            self.index = start;
            return false;
        }
        true
    }

    fn or(&mut self) -> Option<Clause> {
        let first = self.and()?;
        let mut alternatives = false;
        while self.take("||") {
            self.and()?;
            alternatives = true;
        }
        Some(if alternatives { Clause::Other } else { first })
    }

    fn and(&mut self) -> Option<Clause> {
        let mut clauses = vec![self.unary()?];
        while self.take("&&") {
            clauses.push(self.unary()?);
        }
        Some(if clauses.len() == 1 { clauses.swap_remove(0) } else { Clause::And(clauses) })
    }

    fn unary(&mut self) -> Option<Clause> {
        self.skip_space();
        if self.peek(0) == Some(b'!') && self.peek(1).is_some_and(|byte| byte != b'=') {
            self.index += 1;
            self.unary()?;
            return Some(Clause::Other);
        }
        self.primary()
    }

    fn primary(&mut self) -> Option<Clause> {
        if self.take("(") {
            let inner = self.or()?;
            return self.take(")").then_some(inner);
        }
        if self.take_word("true") || self.take_word("false") {
            return Some(Clause::Other);
        }
        let key = self.key()?;
        if self.take("==") || self.take("!=") {
            self.value()?;
            return Some(Clause::Other);
        }
        if self.take("=~") {
            self.regex()?;
            return Some(Clause::Other);
        }
        let before_not = self.index;
        if self.take_word("not") {
            if !self.take_word("in") {
                self.index = before_not;
                return Some(Clause::Has(key));
            }
            self.key()?;
            return Some(Clause::Other);
        }
        if self.take_word("in") {
            self.key()?;
            return Some(Clause::Other);
        }
        Some(Clause::Has(key))
    }

    fn key(&mut self) -> Option<String> {
        self.skip_space();
        let start = self.index;
        while self.peek(0).is_some_and(is_word_byte) {
            self.index += 1;
        }
        (self.index > start).then(|| String::from_utf8_lossy(&self.bytes[start..self.index]).into())
    }

    fn value(&mut self) -> Option<()> {
        self.skip_space();
        let quote = self.peek(0)?;
        if quote == b'\'' || quote == b'"' {
            self.index += 1;
            while self.peek(0)? != quote {
                self.index += 1;
            }
            self.index += 1;
            return Some(());
        }
        let start = self.index;
        while self.peek(0).is_some_and(is_value_byte) {
            self.index += 1;
        }
        (self.index > start).then_some(())
    }

    fn regex(&mut self) -> Option<()> {
        self.skip_space();
        if self.peek(0)? != b'/' {
            return None;
        }
        self.index += 1;
        while self.peek(0)? != b'/' {
            if self.peek(0) == Some(b'\\') && self.peek(1).is_some() {
                self.index += 1;
            }
            self.index += 1;
        }
        self.index += 1;
        while self.peek(0).is_some_and(is_word_byte) {
            self.index += 1;
        }
        Some(())
    }
}
