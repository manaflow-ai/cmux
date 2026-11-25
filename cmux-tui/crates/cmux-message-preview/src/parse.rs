//! One pass over a message's lines: blocks (fences, tables, quotes, headings,
//! list items, rules) by line, then each line's inline Markdown. The same steps
//! as CmuxHomeCore's `PreviewParser` (Swift), read for read; only checked reads
//! (`get`), so no input can panic it.

use crate::{Image, Piece, Table, folded};

/// Bytes that may start Markdown syntax; a text with none of them is plain.
const MARKERS: &[u8] = b"*_`#>[]!|<\\~-+=";

pub(crate) fn parse(markdown: &str) -> (Vec<Piece>, Vec<Image>) {
    let mut p = Parser::default();
    if !markdown.bytes().any(|b| MARKERS.contains(&b)) {
        p.words.push_str(markdown);
        p.flush();
        return (p.pieces, p.images);
    }
    let normalized = markdown.replace("\r\n", "\n").replace('\r', "\n");
    let lines: Vec<&str> = normalized.split('\n').collect();
    let mut fence: Option<&str> = None;
    let mut i = 0usize;
    while let Some(&line) = lines.get(i) {
        let trimmed = line.trim_start_matches([' ', '\t']);
        if let Some(open) = fence {
            if trimmed.starts_with(open) {
                fence = None;
            } else {
                p.append(line);
            }
            i = i.saturating_add(1);
            continue;
        }
        if trimmed.starts_with("```") {
            fence = Some("```");
            i = i.saturating_add(1);
            continue;
        }
        if trimmed.starts_with("~~~") {
            fence = Some("~~~");
            i = i.saturating_add(1);
            continue;
        }
        if line.contains('|')
            && let Some(next) = lines.get(i.saturating_add(1))
            && let Some(columns) = delimiter_columns(next)
        {
            let header = cells(line);
            if header.len() == columns {
                let mut end = i.saturating_add(2);
                let mut rows = 0usize;
                while let Some(&row) = lines.get(end) {
                    if !row.contains('|') || row.chars().all(|c| c == ' ' || c == '\t') {
                        break;
                    }
                    for cell in cells(row) {
                        p.inline(&cell);
                    }
                    rows = rows.saturating_add(1);
                    end = end.saturating_add(1);
                }
                p.flush();
                let columns = header
                    .iter()
                    .map(|cell| {
                        let words = p.inline(cell);
                        folded(&words)
                    })
                    .filter(|title| !title.is_empty())
                    .collect();
                p.pieces.push(Piece::Table(Table { columns, rows }));
                i = end;
                continue;
            }
        }
        let body = block_body(trimmed);
        let words = p.inline(&body);
        p.append(&words);
        i = i.saturating_add(1);
    }
    p.flush();
    (p.pieces, p.images)
}

#[derive(Default)]
struct Parser {
    pieces: Vec<Piece>,
    images: Vec<Image>,
    words: String,
}

impl Parser {
    fn append(&mut self, s: &str) {
        if s.is_empty() {
            return;
        }
        if !self.words.is_empty() {
            self.words.push(' ');
        }
        self.words.push_str(s);
    }

    fn flush(&mut self) {
        let w = folded(&self.words);
        if !w.is_empty() {
            self.pieces.push(Piece::Words(w));
        }
        self.words.clear();
    }

    /// One line's inline Markdown as its words: links by their labels,
    /// pictures left out (and listed), code by its text, emphasis and strike
    /// markers gone, backslash escapes resolved.
    fn inline(&mut self, s: &str) -> String {
        let chars: Vec<char> = s.chars().collect();
        let mut out = String::with_capacity(s.len());
        let mut i = 0usize;
        let word = |c: Option<&char>| c.is_some_and(|c| c.is_alphanumeric());
        let space = |c: Option<&char>| c.is_none_or(|c| c.is_whitespace());
        while let Some(&ch) = chars.get(i) {
            let next = chars.get(i.saturating_add(1));
            match ch {
                '\\' if next.is_some_and(char::is_ascii_punctuation) => {
                    if let Some(&escaped) = next {
                        out.push(escaped);
                    }
                    i = i.saturating_add(2);
                    continue;
                }
                '`' => {
                    let run = run_of(&chars, i, '`');
                    // The matching run of as many backticks closes the span; without one the backticks are text.
                    let mut j = i.saturating_add(run);
                    let mut close = None;
                    while let Some(&c) = chars.get(j) {
                        if c == '`' {
                            let r = run_of(&chars, j, '`');
                            if r == run {
                                close = Some(j);
                                break;
                            }
                            j = j.saturating_add(r);
                        } else {
                            j = j.saturating_add(1);
                        }
                    }
                    if let Some(close) = close {
                        let code: String = chars
                            .get(i.saturating_add(run)..close)
                            .unwrap_or_default()
                            .iter()
                            .collect();
                        out.push_str(code.trim_matches(|c: char| c == ' ' || c == '\t'));
                        i = close.saturating_add(run);
                    } else {
                        i = i.saturating_add(run);
                    }
                    continue;
                }
                '!' if next == Some(&'[') => {
                    if let Some((label, target, end)) = link(&chars, i.saturating_add(1)) {
                        self.images.push(Image { alt: label, source: source(&target) });
                        i = end;
                        continue;
                    }
                }
                '[' => {
                    if let Some((label, _, end)) = link(&chars, i) {
                        let words = self.inline(&label);
                        out.push_str(&words);
                        i = end;
                        continue;
                    }
                }
                '<' => {
                    // <https://…> autolink: the URL.
                    let after = i.saturating_add(1);
                    if let Some(offset) =
                        chars.get(after..).and_then(|rest| rest.iter().position(|&c| c == '>'))
                        && offset > 0
                    {
                        let close = after.saturating_add(offset);
                        let inside: String =
                            chars.get(after..close).unwrap_or_default().iter().collect();
                        if inside.contains(':') && !inside.contains(' ') {
                            out.push_str(&inside);
                            i = close.saturating_add(1);
                            continue;
                        }
                    }
                }
                '*' | '_' | '~' => {
                    let run = run_of(&chars, i, ch);
                    let before = i.checked_sub(1).and_then(|b| chars.get(b));
                    let after = chars.get(i.saturating_add(run));
                    // An emphasis or strike marker opens before a word or closes after one; `_` inside a word
                    // (snake_case) and a lone `*` between spaces stay.
                    let opens = !space(after) && (space(before) || !word(before));
                    let closes = !space(before) && (space(after) || !word(after));
                    let intraword = word(before) && word(after);
                    let sized = if ch == '~' { run == 2 } else { run <= 3 };
                    if !(sized && (opens || closes) && !(ch == '_' && intraword)) {
                        out.extend(std::iter::repeat_n(ch, run));
                    }
                    i = i.saturating_add(run);
                    continue;
                }
                _ => {}
            }
            out.push(ch);
            i = i.saturating_add(1);
        }
        out
    }
}

/// How many `ch` in a row start at `i`.
fn run_of(chars: &[char], i: usize, ch: char) -> usize {
    chars.get(i..).map_or(0, |rest| rest.iter().take_while(|&&c| c == ch).count())
}

/// A line without its block markers: quote marks, a heading's hashes, a
/// bullet and a task box (a numbered item keeps its number, which says
/// something). A rule or a setext underline has no words.
fn block_body(line: &str) -> String {
    let mut s = line;
    while let Some(rest) = s.strip_prefix('>') {
        s = rest.trim_start_matches(' ');
    }
    let bare: Vec<char> = s.chars().filter(|&c| c != ' ').collect();
    if bare.len() >= 3
        && let Some(&c) = bare.first()
        && "-*_=".contains(c)
        && bare.iter().all(|&x| x == c)
    {
        return String::new();
    }
    let hashes = s.chars().take_while(|&c| c == '#').count();
    if (1..=6).contains(&hashes) {
        let rest = s.trim_start_matches('#');
        if rest.starts_with(' ') || rest.is_empty() {
            return rest.trim_start_matches(' ').trim_end_matches(['#', ' ']).to_string();
        }
    }
    for bullet in ["- ", "* ", "+ "] {
        if let Some(rest) = s.strip_prefix(bullet) {
            s = rest;
            break;
        }
    }
    for task in ["[ ] ", "[x] ", "[X] "] {
        if let Some(rest) = s.strip_prefix(task) {
            s = rest;
        }
    }
    s.to_string()
}

/// The column count of a table's delimiter row (`| --- | :-: |`), or None.
fn delimiter_columns(line: &str) -> Option<usize> {
    if !line.contains('-') || !(line.contains('|') || line.contains(':')) {
        return None;
    }
    let cells = cells(line);
    if cells.is_empty() {
        return None;
    }
    for cell in &cells {
        let c = cell.trim();
        let c = c.strip_prefix(':').unwrap_or(c);
        let c = c.strip_suffix(':').unwrap_or(c);
        if c.is_empty() || !c.chars().all(|x| x == '-') {
            return None;
        }
    }
    Some(cells.len())
}

/// A table row's cells, trimmed, its outer pipes dropped; `\|` and a pipe
/// inside a code span stay in the cell.
fn cells(line: &str) -> Vec<String> {
    let mut cells: Vec<String> = Vec::new();
    let mut cell = String::new();
    let mut code = false;
    let mut chars = line.chars();
    while let Some(ch) = chars.next() {
        if ch == '\\' {
            cell.push(ch);
            if let Some(escaped) = chars.next() {
                cell.push(escaped);
            }
            continue;
        }
        if ch == '`' {
            code = !code;
        }
        if ch == '|' && !code {
            cells.push(std::mem::take(&mut cell));
            continue;
        }
        cell.push(ch);
    }
    cells.push(cell);
    let blank = |c: &String| c.chars().all(|x| x == ' ' || x == '\t');
    let content = line.trim();
    if content.starts_with('|') && cells.first().is_some_and(blank) {
        cells.remove(0);
    }
    if content.ends_with('|') && !content.ends_with("\\|") && cells.last().is_some_and(blank) {
        cells.pop();
    }
    cells.into_iter().map(|c| c.trim_matches([' ', '\t']).to_string()).collect()
}

/// `[label](target)` at `i` (the `[`): the label, the target and the index
/// after the `)`; None when it is not a link.
fn link(chars: &[char], i: usize) -> Option<(String, String, usize)> {
    if chars.get(i) != Some(&'[') {
        return None;
    }
    let mut depth = 0usize;
    let mut j = i;
    let mut close = None;
    while let Some(&c) = chars.get(j) {
        if c == '\\' {
            j = j.saturating_add(2);
            continue;
        }
        if c == '[' {
            depth = depth.saturating_add(1);
        }
        if c == ']' {
            depth = depth.saturating_sub(1);
            if depth == 0 {
                close = Some(j);
                break;
            }
        }
        j = j.saturating_add(1);
    }
    let close = close?;
    if chars.get(close.saturating_add(1)) != Some(&'(') {
        return None;
    }
    let mut k = close.saturating_add(2);
    let mut parens = 1usize;
    loop {
        let c = *chars.get(k)?;
        if c == '(' {
            parens = parens.saturating_add(1);
        }
        if c == ')' {
            parens = parens.saturating_sub(1);
            if parens == 0 {
                break;
            }
        }
        k = k.saturating_add(1);
    }
    let label: String = chars.get(i.saturating_add(1)..close)?.iter().collect();
    let target: String = chars.get(close.saturating_add(2)..k)?.iter().collect();
    Some((label, target, k.saturating_add(1)))
}

/// A link target's source: without a title (`src "title"`) and angle brackets.
fn source(target: &str) -> String {
    let t = target.trim();
    if let Some(rest) = t.strip_prefix('<')
        && let Some(end) = rest.find('>')
    {
        return rest.get(..end).unwrap_or_default().to_string();
    }
    t.split(' ').next().unwrap_or_default().to_string()
}
