//! A small shell lexer: just enough POSIX sh and bash to find every command a
//! string would run and every file it would redirect into.
//!
//! It resolves quoting into plain word text, records the body of every
//! `$(...)`, backtick and `<(...)`/`>(...)` substitution so the caller can
//! classify it too, reads redirections with their targets, and skips heredoc
//! bodies (keeping the substitutions of an unquoted one). Anything it can't
//! close (a quote, a paren, a substitution) is an error, and the caller treats
//! an error as the most machine-needing class.

#[derive(Debug, Clone, Default)]
pub(crate) struct Word {
    /// The word with its quotes and escapes resolved. A substitution stays in
    /// the text only as a placeholder.
    pub(crate) text: String,
    /// The scripts of the command and process substitutions in this word.
    pub(crate) subs: Vec<String>,
    quoted: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RedirectKind {
    /// `>`, `>>`, `>|`, `&>`, `&>>`, `<>`: opens the target for writing.
    Write,
    /// `>&`: a file descriptor copy (`2>&1`), or a write when its target is a
    /// file name.
    DupOrWrite,
    /// `<`, `<&`, `<<<`, `<<`: reads, or feeds a heredoc.
    Read,
}

#[derive(Debug, Clone)]
pub(crate) enum Token {
    Word(Word),
    Redirect {
        kind: RedirectKind,
        op: &'static str,
        target: Word,
    },
    /// `|`, `|&`, `&&`, `||`, `;`, `;;`, a newline, `(` or `)`.
    Separator,
    /// `&` ending a command: it runs in the background.
    Background,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct LexError;

/// Redirection operators, longest first so a prefix never shadows a longer one.
const REDIRECT_OPS: &[(&str, RedirectKind)] = &[
    ("&>>", RedirectKind::Write),
    ("&>", RedirectKind::Write),
    (">>", RedirectKind::Write),
    (">|", RedirectKind::Write),
    (">&", RedirectKind::DupOrWrite),
    ("<<<", RedirectKind::Read),
    ("<<-", RedirectKind::Read),
    ("<<", RedirectKind::Read),
    ("<>", RedirectKind::Write),
    ("<&", RedirectKind::Read),
    (">", RedirectKind::Write),
    ("<", RedirectKind::Read),
];

struct PendingHeredoc {
    token: usize,
    delimiter: String,
    strip_tabs: bool,
    expands: bool,
}

pub(crate) fn lex(src: &str) -> Result<Vec<Token>, LexError> {
    let mut lexer = Lexer::new(src);
    lexer.run()?;
    Ok(lexer.tokens)
}

/// The substitutions an unquoted heredoc body or a `${...}` expansion would
/// run. Quotes don't protect anything in a heredoc body, so this looks for
/// `$(` and backticks anywhere; finding too many only raises the class.
fn substitutions_in(text: &str) -> Result<Vec<String>, LexError> {
    let mut lexer = Lexer::new(text);
    let mut subs = Vec::new();
    while let Some(c) = lexer.peek() {
        match c {
            '\\' => lexer.advance(2),
            '$' if lexer.peek_at(1) == Some('(') => {
                lexer.advance(2);
                let inner = lexer.balanced('(', ')')?;
                // `$((...))` is arithmetic, which runs nothing itself.
                match arithmetic_body(&inner) {
                    Some(arith) => subs.extend(substitutions_in(arith)?),
                    None => subs.push(inner),
                }
            }
            '`' => {
                lexer.advance(1);
                subs.push(lexer.backtick()?);
            }
            _ => lexer.advance(1),
        }
    }
    Ok(subs)
}

/// The expression of `$((expr))`, given what's between `$(` and its `)`:
/// `(expr)` whose first `(` closes at the very end. `$((a); (b))` is a
/// substitution of two subshells, not arithmetic, and anything quoted inside
/// is treated as a substitution too, so it gets classified.
fn arithmetic_body(inner: &str) -> Option<&str> {
    let body = inner.strip_prefix('(')?;
    let mut depth = 1usize;
    for (at, c) in body.char_indices() {
        match c {
            '(' => depth = depth.saturating_add(1),
            ')' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return (at.checked_add(1) == Some(body.len()))
                        .then(|| body.get(..at))
                        .flatten();
                }
            }
            '\'' | '"' | '`' | '\\' => return None,
            _ => {}
        }
    }
    None
}

struct Lexer {
    chars: Vec<char>,
    pos: usize,
    tokens: Vec<Token>,
    pending: Vec<PendingHeredoc>,
    parens: usize,
}

fn is_word_end(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\r' | '\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>')
}

impl Lexer {
    fn new(src: &str) -> Self {
        Self {
            chars: src.chars().collect(),
            pos: 0,
            tokens: Vec::new(),
            pending: Vec::new(),
            parens: 0,
        }
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn peek_at(&self, offset: usize) -> Option<char> {
        self.pos.checked_add(offset).and_then(|at| self.chars.get(at)).copied()
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.peek()?;
        self.advance(1);
        Some(c)
    }

    /// Moves `pos` on by `n` chars. It may pass the end, where `peek` sees nothing.
    fn advance(&mut self, n: usize) {
        self.pos = self.pos.saturating_add(n);
    }

    fn saw_case(&self) -> bool {
        self.tokens
            .iter()
            .any(|token| matches!(token, Token::Word(word) if !word.quoted && word.text == "case"))
    }

    fn run(&mut self) -> Result<(), LexError> {
        while let Some(c) = self.peek() {
            match c {
                ' ' | '\t' | '\r' => self.advance(1),
                '\n' => {
                    self.advance(1);
                    self.tokens.push(Token::Separator);
                    self.read_heredocs()?;
                }
                '#' => {
                    while self.peek().is_some_and(|c| c != '\n') {
                        self.advance(1);
                    }
                }
                ';' => {
                    self.advance(1);
                    if matches!(self.peek(), Some(';' | '&')) {
                        self.advance(1);
                    }
                    self.tokens.push(Token::Separator);
                }
                '&' => match self.peek_at(1) {
                    Some('&') => {
                        self.advance(2);
                        self.tokens.push(Token::Separator);
                    }
                    Some('>') => self.redirect()?,
                    _ => {
                        self.advance(1);
                        self.tokens.push(Token::Background);
                    }
                },
                '|' => {
                    self.advance(1);
                    if matches!(self.peek(), Some('|' | '&')) {
                        self.advance(1);
                    }
                    self.tokens.push(Token::Separator);
                }
                '(' => {
                    self.advance(1);
                    self.parens = self.parens.saturating_add(1);
                    self.tokens.push(Token::Separator);
                }
                ')' => {
                    self.advance(1);
                    match self.parens.checked_sub(1) {
                        Some(open) => self.parens = open,
                        // A case pattern (`a)`) closes nothing; the caller
                        // fails closed on `case` itself.
                        None if self.saw_case() => {}
                        None => return Err(LexError),
                    }
                    self.tokens.push(Token::Separator);
                }
                '<' | '>' if self.peek_at(1) != Some('(') => self.redirect()?,
                _ => {
                    let word = self.word()?;
                    let fd_prefix = !word.quoted
                        && word.subs.is_empty()
                        && word.text.bytes().all(|b| b.is_ascii_digit())
                        && matches!(self.peek(), Some('<' | '>'))
                        && self.peek_at(1) != Some('(');
                    if fd_prefix {
                        // `2>file`: the digits name the descriptor.
                        self.redirect()?;
                    } else {
                        self.tokens.push(Token::Word(word));
                    }
                }
            }
        }
        if self.parens != 0 {
            return Err(LexError);
        }
        Ok(())
    }

    /// Reads one redirection: its operator at `pos`, then its target word.
    fn redirect(&mut self) -> Result<(), LexError> {
        let (op, kind) = REDIRECT_OPS
            .iter()
            .copied()
            .find(|(op, _)| op.chars().enumerate().all(|(i, c)| self.peek_at(i) == Some(c)))
            .ok_or(LexError)?;
        self.advance(op.chars().count());
        while matches!(self.peek(), Some(' ' | '\t')) {
            self.advance(1);
        }
        if self.peek().is_none_or(is_word_end) {
            return Err(LexError);
        }
        let target = self.word()?;
        if op == "<<" || op == "<<-" {
            self.pending.push(PendingHeredoc {
                token: self.tokens.len(),
                delimiter: target.text.clone(),
                strip_tabs: op == "<<-",
                expands: !target.quoted,
            });
        }
        self.tokens.push(Token::Redirect { kind, op, target });
        Ok(())
    }

    /// After a newline, skips the bodies of the heredocs opened on the line
    /// that just ended, keeping the substitutions of each unquoted one.
    fn read_heredocs(&mut self) -> Result<(), LexError> {
        for heredoc in std::mem::take(&mut self.pending) {
            let mut body = String::new();
            while self.peek().is_some() {
                let start = self.pos;
                while self.peek().is_some_and(|c| c != '\n') {
                    self.advance(1);
                }
                let line: String =
                    self.chars.get(start..self.pos).unwrap_or_default().iter().collect();
                self.pos = self.pos.saturating_add(1).min(self.chars.len());
                let check =
                    if heredoc.strip_tabs { line.trim_start_matches('\t') } else { line.as_str() };
                if check == heredoc.delimiter {
                    break;
                }
                body.push_str(&line);
                body.push('\n');
            }
            if heredoc.expands {
                let subs = substitutions_in(&body)?;
                if let Some(Token::Redirect { target, .. }) = self.tokens.get_mut(heredoc.token) {
                    target.subs.extend(subs);
                }
            }
        }
        Ok(())
    }

    /// Reads one word starting at `pos`, up to an unquoted blank or operator.
    fn word(&mut self) -> Result<Word, LexError> {
        let mut word = Word::default();
        while let Some(c) = self.peek() {
            match c {
                '<' | '>' if self.peek_at(1) == Some('(') => {
                    self.advance(2);
                    word.subs.push(self.balanced('(', ')')?);
                    word.text.push_str("<(...)");
                }
                _ if is_word_end(c) => break,
                '\'' => {
                    self.advance(1);
                    word.quoted = true;
                    loop {
                        match self.bump().ok_or(LexError)? {
                            '\'' => break,
                            ch => word.text.push(ch),
                        }
                    }
                }
                '"' => {
                    self.advance(1);
                    word.quoted = true;
                    self.double_quoted(&mut word)?;
                }
                '\\' => {
                    self.advance(1);
                    match self.bump() {
                        None | Some('\n') => {}
                        Some(ch) => {
                            word.quoted = true;
                            word.text.push(ch);
                        }
                    }
                }
                '$' => self.dollar(&mut word, false)?,
                '`' => {
                    self.advance(1);
                    word.subs.push(self.backtick()?);
                    word.text.push_str("`...`");
                }
                _ => {
                    self.advance(1);
                    word.text.push(c);
                }
            }
        }
        Ok(word)
    }

    /// Reads the inside of `"..."`; `pos` is just past the opening quote.
    fn double_quoted(&mut self, word: &mut Word) -> Result<(), LexError> {
        loop {
            match self.peek().ok_or(LexError)? {
                '"' => {
                    self.advance(1);
                    return Ok(());
                }
                '\\' => {
                    self.advance(1);
                    match self.bump().ok_or(LexError)? {
                        '\n' => {}
                        ch @ ('$' | '`' | '"' | '\\') => word.text.push(ch),
                        ch => {
                            word.text.push('\\');
                            word.text.push(ch);
                        }
                    }
                }
                '$' => self.dollar(word, true)?,
                '`' => {
                    self.advance(1);
                    word.subs.push(self.backtick()?);
                    word.text.push_str("`...`");
                }
                ch => {
                    self.advance(1);
                    word.text.push(ch);
                }
            }
        }
    }

    /// Reads an expansion starting with `$` at `pos`.
    fn dollar(&mut self, word: &mut Word, in_double_quotes: bool) -> Result<(), LexError> {
        match self.peek_at(1) {
            Some('(') => {
                self.advance(2);
                let inner = self.balanced('(', ')')?;
                match arithmetic_body(&inner) {
                    // `$((...))` is arithmetic; only a substitution inside it runs.
                    Some(arith) => word.subs.extend(substitutions_in(arith)?),
                    None => word.subs.push(inner),
                }
                word.text.push_str("$(...)");
            }
            Some('{') => {
                self.advance(2);
                let inner = self.balanced('{', '}')?;
                word.subs.extend(substitutions_in(&inner)?);
                word.text.push_str("${");
                word.text.push_str(&inner);
                word.text.push('}');
            }
            Some('\'') if !in_double_quotes => {
                // `$'...'`: a quoted string with C escapes.
                self.advance(2);
                word.quoted = true;
                loop {
                    match self.bump().ok_or(LexError)? {
                        '\'' => break,
                        '\\' => {
                            let ch = self.bump().ok_or(LexError)?;
                            word.text.push(ch);
                        }
                        ch => word.text.push(ch),
                    }
                }
            }
            Some('"') if !in_double_quotes => {
                // `$"..."`: a translatable double-quoted string.
                self.advance(2);
                word.quoted = true;
                self.double_quoted(word)?;
            }
            _ => {
                self.advance(1);
                word.text.push('$');
            }
        }
        Ok(())
    }

    /// Reads up to the `close` matching an `open` just before `pos`, and
    /// returns what's between them. Quotes inside are skipped whole, and so
    /// are heredoc bodies, whose lines may hold an unmatched `close`.
    fn balanced(&mut self, open: char, close: char) -> Result<String, LexError> {
        let mut depth = 1usize;
        let mut inner = String::new();
        let mut heredocs: Vec<(String, bool)> = Vec::new();
        loop {
            let c = self.bump().ok_or(LexError)?;
            match c {
                '\\' => {
                    inner.push(c);
                    inner.push(self.bump().ok_or(LexError)?);
                }
                '\'' => self.copy_single_quoted(&mut inner)?,
                '"' => self.copy_double_quoted(&mut inner)?,
                '`' => {
                    inner.push(c);
                    inner.push_str(&self.backtick()?);
                    inner.push('`');
                }
                '<' if self.peek() == Some('<') && self.peek_at(1) != Some('<') => {
                    self.advance(1);
                    inner.push_str("<<");
                    heredocs.push(self.copy_heredoc_delimiter(&mut inner)?);
                }
                '\n' => {
                    inner.push(c);
                    for (delimiter, strip_tabs) in heredocs.drain(..) {
                        self.copy_heredoc_body(&mut inner, &delimiter, strip_tabs)?;
                    }
                }
                _ if c == close => {
                    depth = depth.saturating_sub(1);
                    if depth == 0 {
                        return Ok(inner);
                    }
                    inner.push(c);
                }
                _ if c == open => {
                    depth = depth.saturating_add(1);
                    inner.push(c);
                }
                _ => inner.push(c),
            }
        }
    }

    /// Copies `'...'`; `pos` is just past the opening quote.
    fn copy_single_quoted(&mut self, inner: &mut String) -> Result<(), LexError> {
        inner.push('\'');
        loop {
            let ch = self.bump().ok_or(LexError)?;
            inner.push(ch);
            if ch == '\'' {
                return Ok(());
            }
        }
    }

    /// Copies `"..."`; `pos` is just past the opening quote.
    fn copy_double_quoted(&mut self, inner: &mut String) -> Result<(), LexError> {
        inner.push('"');
        loop {
            let ch = self.bump().ok_or(LexError)?;
            inner.push(ch);
            match ch {
                '\\' => inner.push(self.bump().ok_or(LexError)?),
                '"' => return Ok(()),
                _ => {}
            }
        }
    }

    /// Copies a heredoc's `-` and delimiter word after `<<`, and returns the
    /// delimiter with its quotes removed and whether tabs are stripped.
    fn copy_heredoc_delimiter(&mut self, inner: &mut String) -> Result<(String, bool), LexError> {
        let strip_tabs = self.peek() == Some('-');
        if strip_tabs {
            self.advance(1);
            inner.push('-');
        }
        while let Some(c @ (' ' | '\t')) = self.peek() {
            self.advance(1);
            inner.push(c);
        }
        let mut delimiter = String::new();
        while let Some(c) = self.peek().filter(|&c| !is_word_end(c)) {
            self.advance(1);
            inner.push(c);
            match c {
                '\'' | '"' => loop {
                    let ch = self.bump().ok_or(LexError)?;
                    inner.push(ch);
                    if ch == c {
                        break;
                    }
                    delimiter.push(ch);
                },
                '\\' => {
                    let ch = self.bump().ok_or(LexError)?;
                    inner.push(ch);
                    delimiter.push(ch);
                }
                _ => delimiter.push(c),
            }
        }
        Ok((delimiter, strip_tabs))
    }

    /// Copies a heredoc body up to and including its delimiter line. A body
    /// with no delimiter line can't be told apart from the rest of the
    /// substitution, so it is an error.
    fn copy_heredoc_body(
        &mut self,
        inner: &mut String,
        delimiter: &str,
        strip_tabs: bool,
    ) -> Result<(), LexError> {
        loop {
            let start = self.pos;
            while self.peek().is_some_and(|c| c != '\n') {
                self.advance(1);
            }
            let line: String = self.chars.get(start..self.pos).unwrap_or_default().iter().collect();
            inner.push_str(&line);
            let check = if strip_tabs { line.trim_start_matches('\t') } else { line.as_str() };
            if check == delimiter {
                return Ok(());
            }
            if self.bump().is_none() {
                return Err(LexError);
            }
            inner.push('\n');
        }
    }

    /// Reads up to the closing backtick; `pos` is just past the opening one.
    fn backtick(&mut self) -> Result<String, LexError> {
        let mut inner = String::new();
        loop {
            match self.bump().ok_or(LexError)? {
                '`' => return Ok(inner),
                '\\' => match self.bump().ok_or(LexError)? {
                    ch @ ('`' | '\\' | '$') => inner.push(ch),
                    ch => {
                        inner.push('\\');
                        inner.push(ch);
                    }
                },
                ch => inner.push(ch),
            }
        }
    }
}
