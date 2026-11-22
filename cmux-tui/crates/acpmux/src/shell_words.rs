//! A small shell lexer for [`crate::host_load::for_each_command`]: the simple commands a script
//! runs, read from the words the shell would execute, not from its text. A quoted argument stays
//! one word (`grep -e 'swift build'` runs `grep`), a heredoc's body is data (`cat <<EOF` ...
//! `EOF`), and a `#` comment runs nothing. What a script does run inside its words is read too:
//! `$(...)`, backticks and `<(...)` are scripts of their own ([`Lexed::subs`]), in a word, inside
//! `${...}` and in an unquoted heredoc's body, which the shell expands.
//!
//! Not a full shell parse: it only has to name programs. Input it cannot read (an unclosed quote,
//! substitution or heredoc) is `None`, and the caller falls back to its loose read, which names
//! more, never less.

/// One simple command: its words, quotes removed, and its pipeline: commands joined by `|` share
/// one, and `;`, `&`, `&&`, `||`, a parenthesis or a line end starts the next.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Command {
    pub words: Vec<String>,
    pub pipeline: usize,
}

/// A script's simple commands, the heredoc bodies it feeds (with the pipeline of the command
/// whose `<<` it is), and the scripts its substitutions run.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Lexed {
    pub commands: Vec<Command>,
    pub heredocs: Vec<(usize, String)>,
    pub subs: Vec<String>,
}

/// Characters that end an unquoted word in a heredoc's delimiter.
fn ends_delimiter(c: char) -> bool {
    c.is_whitespace() || matches!(c, ';' | '|' | '&' | '<' | '>' | '(' | ')')
}

struct Lexer {
    s: Vec<char>,
    i: usize,
    out: Lexed,
    cur: Vec<String>,
    word: Option<String>,
    pipeline: usize,
    /// Heredocs whose bodies start on the next line: (delimiter, strip leading tabs, quoted,
    /// pipeline).
    pending: Vec<(String, bool, bool, usize)>,
}

impl Lexer {
    fn peek(&self, ahead: usize) -> Option<char> {
        self.s.get(self.i + ahead).copied()
    }

    fn push(&mut self, c: char) {
        self.word.get_or_insert_with(String::new).push(c);
    }

    fn end_word(&mut self) {
        if let Some(w) = self.word.take() {
            self.cur.push(w);
        }
    }

    fn end_command(&mut self) {
        self.end_word();
        if !self.cur.is_empty() {
            let words = std::mem::take(&mut self.cur);
            self.out.commands.push(Command { words, pipeline: self.pipeline });
        }
    }

    /// Ends the command and its pipeline.
    fn end_pipeline(&mut self) {
        self.end_command();
        self.pipeline += 1;
    }

    /// From just past an opening `(`, the text up to its matching `)`, and moves past it.
    fn balanced(&mut self) -> Option<String> {
        let start = self.i;
        let mut depth = 1usize;
        while let Some(c) = self.peek(0) {
            self.i += 1;
            match c {
                '\\' => self.i += 1,
                '\'' => self.skip_to('\'')?,
                '"' => self.skip_double()?,
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth == 0 {
                        return Some(self.s.get(start..self.i - 1)?.iter().collect());
                    }
                }
                _ => {}
            }
        }
        None
    }

    fn skip_to(&mut self, end: char) -> Option<()> {
        while let Some(c) = self.peek(0) {
            self.i += 1;
            if c == end {
                return Some(());
            }
        }
        None
    }

    fn skip_double(&mut self) -> Option<()> {
        while let Some(c) = self.peek(0) {
            self.i += 1;
            match c {
                '\\' => self.i += 1,
                '"' => return Some(()),
                _ => {}
            }
        }
        None
    }

    /// From just past an opening backtick, the script up to the closing one.
    fn backtick(&mut self) -> Option<String> {
        let mut text = String::new();
        while let Some(c) = self.peek(0) {
            self.i += 1;
            match c {
                '\\' => {
                    text.push(self.peek(0)?);
                    self.i += 1;
                }
                '`' => return Some(text),
                _ => text.push(c),
            }
        }
        None
    }

    /// The `$` forms: `$(...)` runs a script, `$'...'` is a quote, `${...}` one expansion.
    fn dollar(&mut self) -> Option<()> {
        match self.peek(0) {
            Some('(') => {
                self.i += 1;
                let sub = self.balanced()?;
                self.out.subs.push(sub);
                self.word.get_or_insert_with(String::new);
            }
            Some('\'') => {
                self.i += 1;
                while let Some(c) = self.peek(0) {
                    self.i += 1;
                    match c {
                        '\\' => {
                            let next = self.peek(0)?;
                            self.i += 1;
                            self.push(next);
                        }
                        '\'' => return Some(()),
                        _ => self.push(c),
                    }
                }
                return None;
            }
            Some('{') => {
                self.i += 1;
                self.push('$');
                self.push('{');
                let mut depth = 1usize;
                while let Some(c) = self.peek(0) {
                    self.i += 1;
                    match c {
                        '\\' => {
                            let next = self.peek(0)?;
                            self.i += 1;
                            self.push(next);
                        }
                        '$' if self.peek(0) == Some('(') => {
                            self.i += 1;
                            let sub = self.balanced()?;
                            self.out.subs.push(sub);
                        }
                        '`' => {
                            let sub = self.backtick()?;
                            self.out.subs.push(sub);
                        }
                        '{' => {
                            depth += 1;
                            self.push(c);
                        }
                        '}' => {
                            self.push(c);
                            depth -= 1;
                            if depth == 0 {
                                return Some(());
                            }
                        }
                        _ => self.push(c),
                    }
                }
                return None;
            }
            _ => self.push('$'),
        }
        Some(())
    }

    fn double_quoted(&mut self) -> Option<()> {
        self.word.get_or_insert_with(String::new);
        while let Some(c) = self.peek(0) {
            self.i += 1;
            match c {
                '"' => return Some(()),
                '\\' => {
                    let next = self.peek(0)?;
                    self.i += 1;
                    if !matches!(next, '$' | '`' | '"' | '\\' | '\n') {
                        self.push('\\');
                    }
                    if next != '\n' {
                        self.push(next);
                    }
                }
                '`' => {
                    let sub = self.backtick()?;
                    self.out.subs.push(sub);
                }
                '$' if self.peek(0) == Some('(') => self.dollar()?,
                _ => self.push(c),
            }
        }
        None
    }

    /// Past `<<` (or `<<-`): reads the delimiter word, quotes removed, and queues the body.
    fn heredoc(&mut self) -> Option<()> {
        self.end_word();
        let strip = self.peek(0) == Some('-');
        if strip {
            self.i += 1;
        }
        while matches!(self.peek(0), Some(' ' | '\t')) {
            self.i += 1;
        }
        let mut delim = String::new();
        let mut quoted = false;
        while let Some(c) = self.peek(0) {
            if ends_delimiter(c) {
                break;
            }
            self.i += 1;
            match c {
                '\'' | '"' => {
                    quoted = true;
                    while let Some(q) = self.peek(0) {
                        self.i += 1;
                        if q == c {
                            break;
                        }
                        delim.push(q);
                    }
                }
                '\\' => {
                    quoted = true;
                    delim.push(self.peek(0)?);
                    self.i += 1;
                }
                _ => delim.push(c),
            }
        }
        if delim.is_empty() {
            return None;
        }
        self.pending.push((delim, strip, quoted, self.pipeline));
        Some(())
    }

    /// At the start of a line: every queued heredoc's body, each up to its delimiter line. The
    /// shell expands an unquoted delimiter's body, so the substitutions in it run.
    fn bodies(&mut self) -> Option<()> {
        for (delim, strip, quoted, pipeline) in std::mem::take(&mut self.pending) {
            let mut body = String::new();
            loop {
                if self.i >= self.s.len() {
                    return None;
                }
                let start = self.i;
                while self.peek(0).is_some_and(|c| c != '\n') {
                    self.i += 1;
                }
                let text: String = self.s.get(start..self.i)?.iter().collect();
                self.i += 1; // the line end, if any
                let text = if strip { text.trim_start_matches('\t') } else { text.as_str() };
                if text == delim {
                    break;
                }
                body.push_str(text);
                body.push('\n');
            }
            if !quoted {
                let subs = substitutions(&body)?;
                self.out.subs.extend(subs);
            }
            self.out.heredocs.push((pipeline, body));
        }
        Some(())
    }

    fn run(mut self) -> Option<Lexed> {
        while let Some(c) = self.peek(0) {
            self.i += 1;
            match c {
                ' ' | '\t' | '\r' => self.end_word(),
                '\n' => {
                    self.end_command();
                    let pending = !self.pending.is_empty();
                    if pending {
                        self.bodies()?;
                    }
                    self.pipeline += 1;
                }
                '&' | '|' | '>' | '<' | '('
                    if self.word.as_deref().is_some_and(|w| w.ends_with(['>', '<'])) =>
                {
                    // A redirection (`2>&1`, `>|`, `<>`) or a process substitution (`<(...)`).
                    if c == '(' {
                        let sub = self.balanced()?;
                        self.out.subs.push(sub);
                    } else {
                        self.push(c);
                    }
                }
                '&' if self.peek(0) == Some('>') => self.push(c),
                '<' if self.peek(0) == Some('<') && self.peek(1) != Some('<') => {
                    self.i += 1;
                    self.heredoc()?;
                }
                '&' if self.peek(0) == Some('&') => {
                    self.i += 1;
                    self.end_pipeline();
                }
                '|' if self.peek(0) == Some('|') => {
                    self.i += 1;
                    self.end_pipeline();
                }
                '|' => self.end_command(),
                ';' | '&' | '(' | ')' => self.end_pipeline(),
                '\'' => {
                    self.word.get_or_insert_with(String::new);
                    loop {
                        let q = self.peek(0)?;
                        self.i += 1;
                        if q == '\'' {
                            break;
                        }
                        self.push(q);
                    }
                }
                '"' => self.double_quoted()?,
                '`' => {
                    let sub = self.backtick()?;
                    self.out.subs.push(sub);
                    self.word.get_or_insert_with(String::new);
                }
                '$' => self.dollar()?,
                '\\' => match self.peek(0) {
                    Some('\n') => self.i += 1,
                    Some(next) => {
                        self.i += 1;
                        self.push(next);
                    }
                    None => self.push('\\'),
                },
                '#' if self.word.is_none() => {
                    while self.peek(0).is_some_and(|c| c != '\n') {
                        self.i += 1;
                    }
                }
                _ => self.push(c),
            }
        }
        self.end_command();
        if !self.pending.is_empty() {
            return None;
        }
        Some(self.out)
    }
}

fn lexer(text: &str) -> Lexer {
    Lexer {
        s: text.chars().collect(),
        i: 0,
        out: Lexed::default(),
        cur: Vec::new(),
        word: None,
        pipeline: 0,
        pending: Vec::new(),
    }
}

/// The scripts the substitutions in expanded text run (`$(...)` and backticks, as in an unquoted
/// heredoc's body), or None when one is unclosed.
fn substitutions(text: &str) -> Option<Vec<String>> {
    let mut l = lexer(text);
    while let Some(c) = l.peek(0) {
        l.i += 1;
        match c {
            '\\' => l.i += 1,
            '$' if l.peek(0) == Some('(') => {
                l.i += 1;
                let sub = l.balanced()?;
                l.out.subs.push(sub);
            }
            '`' => {
                let sub = l.backtick()?;
                l.out.subs.push(sub);
            }
            _ => {}
        }
    }
    Some(l.out.subs)
}

/// The simple commands of `script`, or None when it cannot be read (an unclosed quote,
/// substitution or heredoc).
pub fn lex(script: &str) -> Option<Lexed> {
    lexer(script).run()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(script: &str) -> Vec<Vec<String>> {
        lex(script).unwrap().commands.into_iter().map(|c| c.words).collect()
    }

    #[test]
    fn quotes_keep_an_argument_one_word() {
        assert_eq!(
            words(r#"grep -e 'swift build' "a | b; c""#),
            [["grep", "-e", "swift build", "a | b; c"]]
        );
        assert_eq!(words("echo $'it\\'s' a\\ b"), [["echo", "it's", "a b"]]);
    }

    #[test]
    fn separators_and_redirections() {
        assert_eq!(
            words("a 2>&1 | b && c; d &>log & e"),
            [vec!["a", "2>&1"], vec!["b"], vec!["c"], vec!["d", "&>log"], vec!["e"]]
        );
    }

    #[test]
    fn a_heredoc_body_is_data_and_the_script_goes_on_after_it() {
        let lexed = lex("cat <<'EOF' > f\ntail -f x\nEOF\nls\ncat <<-X\n\twatch\n\tX").unwrap();
        let w: Vec<_> = lexed.commands.iter().map(|c| c.words.clone()).collect();
        assert_eq!(w, [vec!["cat", ">", "f"], vec!["ls"], vec!["cat"]]);
        assert_eq!(lexed.heredocs, [(0, "tail -f x\n".to_owned()), (2, "watch\n".to_owned())]);
        assert!(lexed.subs.is_empty());
    }

    #[test]
    fn an_unquoted_heredoc_body_runs_its_substitutions() {
        let lexed = lex("cat <<EOF\n$(\nswift build\n) `tail -f x` \\$(no)\nEOF").unwrap();
        assert_eq!(lexed.subs, ["\nswift build\n", "tail -f x"]);
        assert!(lex("cat <<'EOF'\n$(swift build)\nEOF").unwrap().subs.is_empty());
        assert!(lex("cat <<\\EOF\n$(swift build)\nEOF").unwrap().subs.is_empty());
    }

    #[test]
    fn pipelines_are_joined_by_a_single_bar() {
        let lexed = lex("a | b && c || d; e & f\ng").unwrap();
        let p: Vec<_> = lexed.commands.iter().map(|c| c.pipeline).collect();
        assert_eq!(p, [0, 0, 1, 2, 3, 4, 5]);
    }

    #[test]
    fn substitutions_are_scripts_of_their_own() {
        let lexed = lex(r#"echo "$(swift build)" `tail -f x` <(watch ls) $((1+2))"#).unwrap();
        assert_eq!(lexed.subs, ["swift build", "tail -f x", "watch ls", "(1+2)"]);
        let lexed = lex(r#"echo "${X:-$(swift build)}" ${Y:-`watch ls`} ${Z#\}}"#).unwrap();
        assert_eq!(lexed.subs, ["swift build", "watch ls"]);
    }

    #[test]
    fn comments_run_nothing() {
        assert_eq!(words("ls # swift build\necho a#b"), [vec!["ls"], vec!["echo", "a#b"]]);
    }

    #[test]
    fn unreadable_input_is_none() {
        for bad in ["echo 'open", "echo \"open", "x $(open", "cat <<EOF\nbody", "echo `open"] {
            assert_eq!(lex(bad), None, "{bad}");
        }
    }
}
