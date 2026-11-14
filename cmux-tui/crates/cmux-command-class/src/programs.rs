//! Commands that take a program: sed and awk. Their program can run a
//! command or write a file, so it is read, and a program the classifier
//! can't see (`-f file`) or can't parse fails closed.

use crate::rules::{is_flag, is_sink};
use crate::{Classification, CommandClass, Verdict};

use CommandClass::{FileRead, FileWrite, Machine};

/// `sed` prints, unless it edits in place or its program runs a command
/// (`e`, `s///e`) or writes a file (`w`, `W`, `s///w`).
pub(crate) fn sed(tail: &[&str]) -> Classification {
    let mut verdict = Verdict::default();
    verdict.add(FileRead, "sed");
    let mut scripts = Vec::new();
    let mut sandbox = false;
    let mut j = 0;
    let mut only_positional = false;
    while let Some(&word) = tail.get(j) {
        j = j.saturating_add(1);
        if only_positional || !is_flag(word) {
            if scripts.is_empty() {
                scripts.push(word);
            }
            continue;
        }
        if word == "--" {
            only_positional = true;
        } else if let Some(long) = word.strip_prefix("--") {
            let (name, value) = long.split_once('=').map_or((long, None), |(n, v)| (n, Some(v)));
            match name {
                "in-place" => verdict.add(FileWrite, "sed -i"),
                "expression" => {
                    scripts.push(value.or_else(|| tail.get(j).copied()).unwrap_or_default());
                }
                "file" => verdict.add(Machine, "sed -f"),
                "sandbox" => sandbox = true,
                _ => {}
            }
            if value.is_none() && matches!(name, "expression" | "file" | "line-length") {
                j = j.saturating_add(1);
            }
        } else {
            let cluster = word.get(1..).unwrap_or_default();
            for (at, c) in cluster.char_indices() {
                let rest = cluster.get(at.saturating_add(c.len_utf8())..).unwrap_or_default();
                match c {
                    // `-i` takes the rest of the cluster as a backup suffix.
                    'i' => {
                        verdict.add(FileWrite, "sed -i");
                        break;
                    }
                    'e' | 'f' | 'l' => {
                        let value = if rest.is_empty() {
                            let next = tail.get(j).copied();
                            j = j.saturating_add(1);
                            next
                        } else {
                            Some(rest)
                        };
                        match c {
                            'e' => scripts.push(value.unwrap_or_default()),
                            'f' => verdict.add(Machine, "sed -f"),
                            _ => {}
                        }
                        break;
                    }
                    _ => {}
                }
            }
        }
    }
    if !sandbox {
        for (class, reason) in scripts.into_iter().filter_map(sed_program) {
            verdict.add(class, reason);
        }
    }
    verdict.finish()
}

/// The most demanding command of a sed program: `Some((class, reason))` for
/// one that runs or writes, `None` for one that only reads and prints. A
/// program it can't parse is [`Machine`].
fn sed_program(script: &str) -> Option<(CommandClass, &'static str)> {
    let mut parser = SedParser { chars: script.chars().collect(), pos: 0, best: None };
    match parser.program() {
        Some(()) => parser.best,
        None => Some((Machine, "sed program")),
    }
}

struct SedParser {
    chars: Vec<char>,
    pos: usize,
    best: Option<(CommandClass, &'static str)>,
}

impl SedParser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    /// Moves `pos` on by `n` chars. It may pass the end, where `peek` sees nothing.
    fn advance(&mut self, n: usize) {
        self.pos = self.pos.saturating_add(n);
    }

    fn raise(&mut self, class: CommandClass, reason: &'static str) {
        if self.best.is_none_or(|(best, _)| class > best) {
            self.best = Some((class, reason));
        }
    }

    fn skip_blanks(&mut self) {
        while self.peek().is_some_and(|c| c == ' ' || c == '\t') {
            self.advance(1);
        }
    }

    /// The rest of the line, as a file name or label.
    fn rest_of_line(&mut self) -> String {
        let start = self.pos;
        while self.peek().is_some_and(|c| c != '\n') {
            self.advance(1);
        }
        self.chars
            .get(start..self.pos)
            .unwrap_or_default()
            .iter()
            .collect::<String>()
            .trim()
            .to_owned()
    }

    fn program(&mut self) -> Option<()> {
        loop {
            while self.peek().is_some_and(|c| c.is_whitespace() || c == ';') {
                self.advance(1);
            }
            let Some(c) = self.peek() else {
                return Some(());
            };
            if c == '#' {
                self.rest_of_line();
                continue;
            }
            self.address()?;
            self.skip_blanks();
            if self.peek() == Some(',') {
                self.advance(1);
                self.skip_blanks();
                self.address()?;
            }
            self.skip_blanks();
            while self.peek() == Some('!') {
                self.advance(1);
                self.skip_blanks();
            }
            self.command()?;
        }
    }

    fn address(&mut self) -> Option<()> {
        match self.peek() {
            Some(c) if c.is_ascii_digit() || c == '+' || c == '~' => {
                self.advance(1);
                while self.peek().is_some_and(|c| c.is_ascii_digit() || c == '~') {
                    self.advance(1);
                }
            }
            Some('$') => self.advance(1),
            Some('/') => {
                self.advance(1);
                self.delimited('/')?;
                self.regex_flags();
            }
            Some('\\') => {
                self.advance(1);
                let delimiter = self.peek()?;
                self.advance(1);
                self.delimited(delimiter)?;
                self.regex_flags();
            }
            _ => {}
        }
        Some(())
    }

    fn regex_flags(&mut self) {
        while matches!(self.peek(), Some('I' | 'M')) {
            self.advance(1);
        }
    }

    /// Skips to just past the next unescaped `delimiter`.
    fn delimited(&mut self, delimiter: char) -> Option<()> {
        loop {
            let c = self.peek()?;
            self.advance(1);
            if c == '\\' {
                self.advance(1);
            } else if c == delimiter {
                return Some(());
            }
        }
    }

    fn command(&mut self) -> Option<()> {
        let c = self.peek()?;
        self.advance(1);
        match c {
            '{' | '}' | '=' | 'd' | 'D' | 'g' | 'G' | 'h' | 'H' | 'n' | 'N' | 'p' | 'P' | 'x'
            | 'z' | 'F' => {}
            'l' | 'L' | 'q' | 'Q' => {
                self.skip_blanks();
                while self.peek().is_some_and(|c| c.is_ascii_digit()) {
                    self.advance(1);
                }
            }
            ':' | 'b' | 't' | 'T' | 'v' => {
                while self.peek().is_some_and(|c| !matches!(c, ';' | '\n' | '}')) {
                    self.advance(1);
                }
            }
            // Text up to an unescaped newline; a file to read.
            'a' | 'i' | 'c' | 'r' | 'R' => self.text(),
            'w' | 'W' => self.write_file("sed w"),
            'e' => {
                self.rest_of_line();
                self.raise(Machine, "sed e");
            }
            's' => self.substitute()?,
            'y' => {
                let delimiter = self.peek()?;
                self.advance(1);
                self.delimited(delimiter)?;
                self.delimited(delimiter)?;
            }
            _ => return None,
        }
        Some(())
    }

    fn text(&mut self) {
        while let Some(c) = self.peek() {
            self.advance(1);
            match c {
                '\\' => self.advance(1),
                '\n' => return,
                _ => {}
            }
        }
    }

    fn write_file(&mut self, reason: &'static str) {
        let file = self.rest_of_line();
        if !is_sink(&file) {
            self.raise(FileWrite, reason);
        }
    }

    fn substitute(&mut self) -> Option<()> {
        let delimiter = self.peek()?;
        self.advance(1);
        self.delimited(delimiter)?;
        self.delimited(delimiter)?;
        while let Some(flag) = self.peek() {
            match flag {
                ';' | '\n' | '}' => return Some(()),
                'g' | 'p' | 'i' | 'I' | 'm' | 'M' | ' ' | '\t' => self.advance(1),
                _ if flag.is_ascii_digit() => self.advance(1),
                'e' => {
                    self.advance(1);
                    self.raise(Machine, "sed s///e");
                }
                'w' => {
                    self.advance(1);
                    self.write_file("sed s///w");
                    return Some(());
                }
                _ => return None,
            }
        }
        Some(())
    }
}

/// `awk` reads, unless its program runs a command (`system()`, a pipe to or
/// from one) or prints into a file (`print > f`, with any expression as `f`).
/// A program in a file, or a gawk extension, can't be seen and fails closed.
pub(crate) fn awk(name: &str, tail: &[&str]) -> Classification {
    let mut j = 0;
    while let Some(&word) = tail.get(j) {
        match word {
            "-f" | "--file" | "-E" | "--exec" | "-i" | "--include" | "-l" | "--load" => {
                return Classification::new(Machine, format!("{name} -f"));
            }
            "-F" | "-v" | "--assign" | "--field-separator" => j = j.saturating_add(2),
            "--" => {
                j = j.saturating_add(1);
                break;
            }
            _ if is_flag(word) => j = j.saturating_add(1),
            _ => break,
        }
    }
    let program = tail.get(j).copied().unwrap_or_default();
    match awk_program(program) {
        Some((class, what)) => Classification::new(class, format!("{name} {what}")),
        None => Classification::new(FileRead, name),
    }
}

/// What an awk program does beyond reading: `Some((Machine, "system"))`,
/// `Some((FileWrite, ">"))`, or `None`.
fn awk_program(program: &str) -> Option<(CommandClass, &'static str)> {
    let Some(code) = awk_code(program) else {
        return Some((Machine, "program"));
    };
    if code.contains("system") || code.contains("@load") || code.contains("@include") {
        return Some((Machine, "system"));
    }
    // After strings and regexes are gone, a lone `|` pipes to or from a
    // command: `print | cmd`, `cmd | getline`, gawk's `|&`.
    let bytes = code.as_bytes();
    let pipe = bytes.iter().enumerate().any(|(at, &b)| {
        b == b'|'
            && at.checked_add(1).and_then(|next| bytes.get(next)) != Some(&b'|')
            && at.checked_sub(1).and_then(|prev| bytes.get(prev)) != Some(&b'|')
    });
    if pipe {
        return Some((Machine, "|"));
    }
    if awk_prints_into_file(&code) {
        return Some((FileWrite, ">"));
    }
    None
}

/// The program with every string literal emptied to `""` (a string that is
/// exactly a sink becomes `@`), and every regex literal emptied to `//`.
/// `None` for an unterminated string or regex.
fn awk_code(program: &str) -> Option<String> {
    let chars: Vec<char> = program.chars().collect();
    let mut code = String::new();
    let mut i = 0;
    while let Some(&c) = chars.get(i) {
        i = i.saturating_add(1);
        match c {
            '"' => {
                let start = i;
                loop {
                    match chars.get(i)? {
                        '\\' => i = i.saturating_add(2),
                        '"' => break,
                        _ => i = i.saturating_add(1),
                    }
                }
                let text: String = chars.get(start..i).unwrap_or_default().iter().collect();
                i = i.saturating_add(1);
                code.push_str(if is_sink(&text) { "@" } else { "\"\"" });
            }
            '/' if starts_regex(&code) => {
                let mut in_class = false;
                loop {
                    match chars.get(i)? {
                        '\\' => i = i.saturating_add(1),
                        '[' => in_class = true,
                        ']' => in_class = false,
                        '/' if !in_class => break,
                        _ => {}
                    }
                    i = i.saturating_add(1);
                }
                i = i.saturating_add(1);
                code.push_str("//");
            }
            _ => code.push(c),
        }
    }
    Some(code)
}

/// A `/` starts a regex where an operand can't end: at the start, or after
/// an operator or opening bracket.
fn starts_regex(code_before: &str) -> bool {
    match code_before.trim_end().chars().last() {
        None => true,
        Some(c) => "(,~!{};&|=<>?:+-*%^\n".contains(c),
    }
}

/// Whether a `print` or `printf` statement redirects with `>` or `>>`
/// outside parentheses (inside them, `>` compares), to anything but a sink.
fn awk_prints_into_file(code: &str) -> bool {
    code.split([';', '{', '}', '\n']).any(|statement| {
        let Some(at) = find_word(statement, "print").or_else(|| find_word(statement, "printf"))
        else {
            return false;
        };
        let mut depth = 0i32;
        let rest = statement.get(at..).unwrap_or_default();
        rest.char_indices().any(|(i, c)| match c {
            '(' => {
                depth = depth.saturating_add(1);
                false
            }
            ')' => {
                depth = depth.saturating_sub(1);
                false
            }
            '>' if depth <= 0 => !rest
                .get(i..)
                .unwrap_or_default()
                .trim_start_matches('>')
                .trim_start()
                .starts_with('@'),
            _ => false,
        })
    })
}

/// The byte offset of `word` standing alone (not part of a longer name).
fn find_word(text: &str, word: &str) -> Option<usize> {
    let is_name = |c: char| c.is_ascii_alphanumeric() || c == '_';
    text.match_indices(word).map(|(at, _)| at).find(|&at| {
        let before =
            text.get(..at).unwrap_or_default().chars().next_back().is_none_or(|c| !is_name(c));
        let after = text
            .get(at.saturating_add(word.len())..)
            .unwrap_or_default()
            .chars()
            .next()
            .is_none_or(|c| !is_name(c));
        before && after
    })
}
