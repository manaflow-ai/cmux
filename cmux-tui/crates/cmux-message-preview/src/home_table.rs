//! A Markdown pipe table in a Home reply, found, parsed and read the way the Mac app's Home
//! transcript draws it: the Rust port of MessagesLabHome's `HomeTable.swift` (`HomeTableSplitter`,
//! `HomeTableCell`, `HomePlanCard`, `HomeTableColumns`) and the GitHub link reading of
//! `ChiefPlanPullRequest`.
//!
//! Home draws a reply's table as a card of its own at the chat's full width (Leo 2026-10-20: a
//! three-column table squeezed into a bubble wrapped every cell into a tall column of words), or,
//! when it is an assignment list (who does what, with an owner column of subagent ids), as the
//! Chief's plan card. These are the values only; the app draws them.
//!
//! Text is read as Swift reads it: by extended grapheme cluster wherever Swift walks a `String`'s
//! `Character`s, by Unicode scalar where Swift trims with a `CharacterSet`, and with Swift's
//! `.whitespaces` set (tab and the space separators, category Zs). Bold ranges count UTF-16 code
//! units, as an `NSRange` does.

use unicode_segmentation::UnicodeSegmentation;

/// Tables larger than this stay text (a pasted CSV is not a card).
pub const MAX_ROWS: usize = 200;
/// Tables wider than this stay text.
pub const MAX_COLUMNS: usize = 12;
/// The narrowest a shared column gets ([`column_widths`]).
pub const MIN_COLUMN: f64 = 56.0;
/// The source scheme of a table picture that is one of the message's attachments.
pub const ATTACHMENT_SCHEME: &str = "cmux-attachment:";

/// A column's alignment, from its delimiter row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Alignment {
    Leading,
    Center,
    Trailing,
}

impl Alignment {
    /// Swift's raw value (`HomeTable.Alignment`).
    pub fn name(self) -> &'static str {
        match self {
            Self::Leading => "leading",
            Self::Center => "center",
            Self::Trailing => "trailing",
        }
    }
}

/// A parsed table: its header cells and body rows as Markdown, as written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Table {
    pub header: Vec<String>,
    pub alignments: Vec<Alignment>,
    /// Body rows, each padded or cut to the header's column count.
    pub rows: Vec<Vec<String>>,
}

impl Table {
    pub fn columns(&self) -> usize {
        self.header.len()
    }

    /// Every cell, the header's first.
    fn cells(&self) -> impl Iterator<Item = &String> {
        self.header.iter().chain(self.rows.iter().flatten())
    }
}

/// A piece of a reply: text as written, or a table with the exact Markdown it came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Segment {
    Text(String),
    Table { table: Table, raw: String },
}

/// Swift's `CharacterSet.whitespaces`: tab and category Zs.
fn is_ws(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

fn trim_ws(s: &str) -> &str {
    s.trim_matches(is_ws)
}

fn graphemes(s: &str) -> Vec<&str> {
    s.graphemes(true).collect()
}

/// `text` cut at its pipe tables: the text between them as written, each table parsed (a table
/// Home refuses, too long or too wide or with no body row, joins the text again). A table inside
/// a ```` ``` ```` or `~~~` fence is code and stays text.
pub fn segments(text: &str) -> Vec<Segment> {
    if !text.contains('|') {
        return vec![Segment::Text(text.to_owned())];
    }
    let lines: Vec<&str> = text.split('\n').collect();
    let mut out = Vec::new();
    let mut pending: Vec<&str> = Vec::new();
    let mut fence = None;
    let flush = |pending: &mut Vec<&str>, out: &mut Vec<Segment>| {
        if !pending.is_empty() {
            out.push(Segment::Text(pending.join("\n")));
            pending.clear();
        }
    };
    let mut i = 0;
    while let Some(&line) = lines.get(i) {
        let trimmed = trim_ws(line);
        if let Some(open) = fence {
            pending.push(line);
            if trimmed.starts_with(open) {
                fence = None;
            }
            i += 1;
            continue;
        }
        if let Some(marker) = ["```", "~~~"].into_iter().find(|marker| trimmed.starts_with(*marker))
        {
            fence = Some(marker);
            pending.push(line);
            i += 1;
            continue;
        }
        if let (Some(next), Some(header)) = (lines.get(i + 1), cells(line))
            && header.len() >= 2
            && let Some(alignments) = delimiter(next, header.len())
        {
            let mut rows = Vec::new();
            let mut j = i + 2;
            while let Some(row) = lines.get(j) {
                if trim_ws(row).is_empty() {
                    break;
                }
                let Some(cells) = cells(row) else { break };
                rows.push(fit(cells, header.len()));
                j += 1;
            }
            if !rows.is_empty()
                && rows.len() <= MAX_ROWS
                && header.len() <= MAX_COLUMNS
                && let Some(raw_lines) = lines.get(i..j)
            {
                flush(&mut pending, &mut out);
                let raw = raw_lines.join("\n");
                out.push(Segment::Table { table: Table { header, alignments, rows }, raw });
                i = j;
                continue;
            }
        }
        pending.push(line);
        i += 1;
    }
    flush(&mut pending, &mut out);
    out
}

/// A row's cells: the line must hold a pipe outside code spans and escapes; the outer pipes are
/// optional. `None` for a line that is not a table row.
pub fn cells(line: &str) -> Option<Vec<String>> {
    let graphemes = graphemes(trim_ws(line));
    let mut s = graphemes.as_slice();
    if !s.contains(&"|") {
        return None;
    }
    if let ["|", rest @ ..] = s {
        s = rest;
    }
    if let [rest @ .., "|"] = s
        && rest.last() != Some(&"\\")
    {
        s = rest;
    }
    let mut cells = Vec::new();
    let mut cell = String::new();
    let mut code = false;
    let mut escaped = false;
    for &ch in s {
        if escaped {
            if ch != "|" {
                cell.push('\\');
            }
            cell.push_str(ch);
            escaped = false;
            continue;
        }
        match ch {
            "\\" => escaped = true,
            "`" => {
                code = !code;
                cell.push_str(ch);
            }
            "|" if !code => {
                cells.push(trim_ws(&cell).to_owned());
                cell.clear();
            }
            _ => cell.push_str(ch),
        }
    }
    if escaped {
        cell.push('\\');
    }
    cells.push(trim_ws(&cell).to_owned());
    (cells.len() >= 2).then_some(cells)
}

/// The delimiter row (`|---|:---:|--:|`) for `columns` columns: each column's alignment.
pub fn delimiter(line: &str, columns: usize) -> Option<Vec<Alignment>> {
    let cells = cells(line)?;
    if cells.len() != columns {
        return None;
    }
    let mut out = Vec::with_capacity(columns);
    for cell in &cells {
        let g = graphemes(cell);
        let left = g.first() == Some(&":");
        let right = g.last() == Some(&":");
        let dashes = cell.trim_matches(':');
        if dashes.is_empty() || !dashes.chars().all(|c| c == '-') {
            return None;
        }
        out.push(match (left, right) {
            (true, true) => Alignment::Center,
            (_, true) => Alignment::Trailing,
            _ => Alignment::Leading,
        });
    }
    Some(out)
}

fn fit(mut cells: Vec<String>, count: usize) -> Vec<String> {
    cells.resize(count, String::new());
    cells
}

/// A picture a cell names: `![alt](source)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Image {
    pub alt: String,
    pub source: String,
}

/// A table cell's Markdown as the card shows it: the text without emphasis and code marks, its
/// links' titles in place, the links it carries and the pictures it names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cell {
    pub text: String,
    /// `(location, length)` in `text`'s UTF-16 code units of each `**bold**` run.
    pub bold: Vec<(usize, usize)>,
    /// Each link as Foundation's `URL(string:)` writes it back (`absoluteString`).
    pub links: Vec<String>,
    /// The pictures, in the cell's order (their syntax is not in `text`).
    pub images: Vec<Image>,
}

/// The first index at or after `from` of `target` in `chars`.
fn find(chars: &[&str], from: usize, target: &str) -> Option<usize> {
    chars.get(from..)?.iter().position(|c| *c == target).map(|p| p + from)
}

/// Parses one cell's Markdown (Swift `HomeTableCell(markdown:)`).
pub fn cell(markdown: &str) -> Cell {
    let chars = graphemes(markdown);
    let mut text = String::new();
    let mut len16 = 0usize;
    let mut bold = Vec::new();
    let mut links: Vec<String> = Vec::new();
    let mut images = Vec::new();
    let mut bold_start: Option<usize> = None;
    let push = |text: &mut String, len16: &mut usize, s: &str| {
        text.push_str(s);
        *len16 += s.encode_utf16().count();
    };
    let mut i = 0;
    while let Some(&ch) = chars.get(i) {
        if (ch == "*" || ch == "_") && chars.get(i + 1) == Some(&ch) {
            match bold_start.take() {
                Some(start) => bold.push((start, len16 - start)),
                None => bold_start = Some(len16),
            }
            i += 2;
            continue;
        }
        if ch == "`" {
            i += 1;
            continue;
        }
        // ![alt](source): a picture; not text.
        if ch == "!"
            && chars.get(i + 1) == Some(&"[")
            && let Some(close) = find(&chars, i + 2, "]")
            && chars.get(close + 1) == Some(&"(")
            && let Some(end) = find(&chars, close + 2, ")")
            && let Some(alt) = chars.get(i + 2..close)
            && let Some(source) = chars.get(close + 2..end)
        {
            let alt = alt.concat();
            let source = source.concat().trim_matches([' ', '<', '>']).to_owned();
            images.push(Image { alt, source });
            i = end + 1;
            continue;
        }
        // [title](url)
        if ch == "["
            && let Some(close) = find(&chars, i + 1, "]")
            && chars.get(close + 1) == Some(&"(")
            && let Some(end) = find(&chars, close + 2, ")")
            && let Some(title) = chars.get(i + 1..close)
            && let Some(target) = chars.get(close + 2..end)
            && let Some(url) = url_with_scheme(&target.concat())
        {
            push(&mut text, &mut len16, &title.concat());
            links.push(url);
            i = end + 1;
            continue;
        }
        push(&mut text, &mut len16, ch);
        i += 1;
    }
    // A bare link (`https://…`) counts too.
    for word in split_graphemes(&text, |g| g == " " || g == "," || g == ";") {
        let w = word.trim_matches(['(', ')', '<', '>', '.']);
        if w.starts_with("https://")
            && let Some(url) = url_with_scheme(w)
            && !links.contains(&url)
        {
            links.push(url);
        }
    }
    Cell { text: trim_ws(&text).to_owned(), bold, links, images }
}

/// `s` split at the graphemes `sep` matches, empty pieces left out (Swift `split(whereSeparator:)`).
fn split_graphemes(s: &str, sep: impl Fn(&str) -> bool) -> Vec<String> {
    let mut out = Vec::new();
    let mut piece = String::new();
    for g in s.graphemes(true) {
        if sep(g) {
            if !piece.is_empty() {
                out.push(std::mem::take(&mut piece));
            }
        } else {
            piece.push_str(g);
        }
    }
    if !piece.is_empty() {
        out.push(piece);
    }
    out
}

/// `target` as Foundation's `URL(string:)` (macOS 14 and later, which percent-encodes characters a
/// URL cannot hold) writes it back, when it parses and has a scheme; `None` otherwise.
fn url_with_scheme(target: &str) -> Option<String> {
    let (scheme, _) = target.split_once(':')?;
    let mut bytes = scheme.bytes();
    if !bytes.next()?.is_ascii_alphabetic()
        || !bytes.all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'-' | b'.'))
    {
        return None;
    }
    let raw = target.as_bytes();
    let mut out = String::with_capacity(target.len());
    for (i, &b) in raw.iter().enumerate() {
        let keep = b.is_ascii_alphanumeric()
            || b"-._~:/?#[]@!$&'()*+,;=".contains(&b)
            || (b == b'%'
                && raw.get(i + 1).is_some_and(u8::is_ascii_hexdigit)
                && raw.get(i + 2).is_some_and(u8::is_ascii_hexdigit));
        if keep {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    Some(out)
}

/// The attachment hashes `text`'s tables show in their cells (each draws there, not again below
/// the text), in sorted order.
pub fn attachment_hashes(text: &str) -> Vec<String> {
    if !text.contains(ATTACHMENT_SCHEME) {
        return Vec::new();
    }
    let mut out = std::collections::BTreeSet::new();
    for segment in segments(text) {
        let Segment::Table { table, .. } = segment else { continue };
        for c in table.cells() {
            for image in cell(c).images {
                if let Some(hash) = image.source.strip_prefix(ATTACHMENT_SCHEME) {
                    out.insert(hash.to_owned());
                }
            }
        }
    }
    out.into_iter().collect()
}

/// A plan row's state as the table's own words give it (Swift `ChiefPlanStep.State`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WrittenState {
    Working,
    NeedsInput,
    WaitingOnCi,
    CiFailed,
    InReview,
    Landed,
    Done,
}

impl WrittenState {
    /// Swift's raw value.
    pub fn name(self) -> &'static str {
        match self {
            Self::Working => "working",
            Self::NeedsInput => "needsInput",
            Self::WaitingOnCi => "waitingOnCI",
            Self::CiFailed => "ciFailed",
            Self::InReview => "inReview",
            Self::Landed => "landed",
            Self::Done => "done",
        }
    }
}

/// One step of a plan card.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanRow {
    /// The row's short key column (`1 + 2`, `PR 3`), when it has one.
    pub key: Option<String>,
    pub title: String,
    /// The subagent id (`a12`), lowercased.
    pub owner: Option<String>,
    /// The owner cell after its id (`new; workspace "a12 · Nightly train"`).
    pub owner_note: Option<String>,
    /// GitHub pull request links in the row, in order, without repeats.
    pub pull_requests: Vec<String>,
    /// The state the table's status column gives.
    pub written: Option<WrittenState>,
}

/// Header words that name the owner column.
pub const OWNER_HEADERS: [&str; 9] =
    ["who", "owner", "owners", "agent", "subagent", "lane", "assignee", "assigned", "assigned to"];
/// Header words that name the status column.
pub const STATUS_HEADERS: [&str; 4] = ["status", "state", "where", "progress"];

/// `table` as the Chief's plan card, or `None` when it is not an assignment list: it needs a
/// column whose header names an owner (Who, Owner, Agent, Lane), and at least half its rows must
/// name a subagent (Swift `HomePlanCard.init?(_:)`).
pub fn plan_card(table: &Table) -> Option<Vec<PlanRow>> {
    let columns = table.columns();
    if columns < 2 {
        return None;
    }
    let at = |row: &Vec<String>, c: usize| row.get(c).map(String::as_str).unwrap_or("").to_owned();
    let headers: Vec<String> =
        table.header.iter().map(|h| trim_ws(&cell(h).text.to_lowercase()).to_owned()).collect();
    let owner_column = headers.iter().position(|h| OWNER_HEADERS.contains(&h.as_str()))?;
    let owned =
        table.rows.iter().filter(|r| owner_id(&cell(&at(r, owner_column)).text).is_some()).count();
    if owned * 2 < table.rows.len() || owned == 0 {
        return None;
    }
    let status_column = headers.iter().position(|h| STATUS_HEADERS.contains(&h.as_str()));
    let others: Vec<usize> =
        (0..columns).filter(|&c| c != owner_column && Some(c) != status_column).collect();
    // The title is the column with the most words (the first of equals); a short column before it is the key.
    let words = |c: usize| -> usize {
        table.rows.iter().map(|r| split_graphemes(&cell(&at(r, c)).text, |g| g == " ").len()).sum()
    };
    let counts: Vec<(usize, usize)> = others.iter().map(|&c| (c, words(c))).collect();
    let (&(mut title_column, mut most), rest) = counts.split_first()?;
    for &(c, n) in rest {
        if n > most {
            title_column = c;
            most = n;
        }
    }
    let key_column = counts
        .iter()
        .find(|&&(c, n)| c != title_column && n <= table.rows.len() * 3)
        .map(|&(c, _)| c);
    let rows = table
        .rows
        .iter()
        .map(|cells| {
            let parsed: Vec<Cell> = cells.iter().map(|c| cell(c)).collect();
            let text = |c: usize| parsed.get(c).map(|p| p.text.clone());
            let owner_cell = text(owner_column).unwrap_or_default();
            let owner = owner_id(&owner_cell);
            let owner_note = owner.as_deref().and_then(|o| note(&owner_cell, o));
            let mut pull_requests: Vec<String> = Vec::new();
            for url in parsed.iter().flat_map(|p| &p.links) {
                if let Some(pr) = pull_request_url(url)
                    && !pull_requests.contains(&pr)
                {
                    pull_requests.push(pr);
                }
            }
            PlanRow {
                key: key_column.and_then(text).filter(|k| !k.is_empty()),
                title: text(title_column).unwrap_or_default(),
                owner,
                owner_note,
                pull_requests,
                written: status_column.and_then(text).and_then(|t| written_state(&t)),
            }
        })
        .collect();
    Some(rows)
}

/// `a12` when `text` starts with a subagent id (`a12`, `A7, added …`), lowercased.
pub fn owner_id(text: &str) -> Option<String> {
    let g = graphemes(trim_ws(text));
    let ["a" | "A", suffix @ ..] = g.as_slice() else {
        return None;
    };
    let digits: Vec<&str> =
        suffix.iter().take_while(|d| matches!(d.as_bytes(), [b'0'..=b'9'])).copied().collect();
    if digits.is_empty() || digits.len() > 4 {
        return None;
    }
    if let Some(after) = suffix.get(digits.len()).and_then(|a| a.chars().next())
        && (after.is_alphabetic() || after.is_numeric())
    {
        return None;
    }
    Some(format!("a{}", digits.concat()))
}

/// The owner cell after its id, without the separator or the parentheses around it:
/// `a12 (new; workspace …)` is `new; workspace …`; `None` when nothing follows.
pub fn note(cell: &str, owner: &str) -> Option<String> {
    let owner_len = owner.graphemes(true).count();
    let rest: String = trim_ws(cell).graphemes(true).skip(owner_len).collect();
    let mut note = rest.trim_matches(|c: char| ",;:-–—".contains(c) || is_ws(c)).to_owned();
    let g = graphemes(&note);
    if let ["(", inner @ .., ")"] = g.as_slice() {
        note = trim_ws(&inner.concat()).to_owned();
    }
    (!note.is_empty()).then_some(note)
}

/// The state a status cell's words give, or `None`.
pub fn written_state(text: &str) -> Option<WrittenState> {
    let lower = text.to_lowercase();
    let words = split_graphemes(&lower, |g| !g.chars().next().is_some_and(char::is_alphabetic));
    let has = |list: &[&str]| words.iter().any(|w| list.contains(&w.as_str()));
    if has(&["landed", "merged", "shipped"]) {
        Some(WrittenState::Landed)
    } else if has(&["failed", "failing", "red", "broken"]) {
        Some(WrittenState::CiFailed)
    } else if has(&["ci", "checks"]) {
        Some(WrittenState::WaitingOnCi)
    } else if has(&["review", "reviewing", "ready"]) {
        Some(WrittenState::InReview)
    } else if has(&["waiting", "blocked", "needs"]) {
        Some(WrittenState::NeedsInput)
    } else if has(&["done", "finished", "complete"]) {
        Some(WrittenState::Done)
    } else if has(&["working", "running", "building", "started"]) {
        Some(WrittenState::Working)
    } else {
        None
    }
}

fn percent_decoded(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while let Some(&current) = b.get(i) {
        if current == b'%'
            && let Some(byte) = s.get(i + 1..i + 3).and_then(|h| u8::from_str_radix(h, 16).ok())
        {
            out.push(byte);
            i += 3;
            continue;
        }
        out.push(current);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// `owner/repo#N` for a GitHub pull request link (`https://github.com/OWNER/REPO/pull/N`, any
/// trailing path), lowercased; `None` for anything else (Swift `ChiefPlanPullRequest.key`).
pub fn pull_request_key(link: &str) -> Option<String> {
    let rest = link.strip_prefix("https://")?;
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let (authority, after) = rest.split_at_checked(end)?;
    let host = authority.rsplit('@').next().unwrap_or(authority);
    let host = match host.rsplit_once(':') {
        Some((hostname, port)) if port.bytes().all(|b| b.is_ascii_digit()) => hostname,
        _ => host,
    };
    if !host.eq_ignore_ascii_case("github.com") {
        return None;
    }
    let path = after.split(['?', '#']).next()?;
    let mut parts = path.split('/').filter(|p| !p.is_empty()).map(percent_decoded);
    let owner = parts.next()?;
    let repo = parts.next()?;
    if parts.next()?.as_str() != "pull" {
        return None;
    }
    let number: i64 = parts.next()?.parse().ok()?;
    if number <= 0 {
        return None;
    }
    Some(format!("{}/{}#{number}", owner.to_lowercase(), repo.to_lowercase()))
}

/// The canonical `https://github.com/owner/repo/pull/N` of a GitHub pull request link (Swift
/// `ChiefPlanPullRequest(link:)`'s `url`).
pub fn pull_request_url(link: &str) -> Option<String> {
    let key = pull_request_key(link)?;
    let parts: Vec<&str> = key.split('#').filter(|p| !p.is_empty()).collect();
    let [repo, number] = parts.as_slice() else { return None };
    let number: i64 = number.parse().ok()?;
    Some(format!("https://github.com/{repo}/pull/{number}"))
}

/// Column widths for a table card: each column gets its natural width (its widest cell) when they
/// all fit; otherwise narrow columns keep theirs and the wide ones share the rest in proportion to
/// their natural widths, never under [`MIN_COLUMN`] (Swift `HomeTableColumns.widths`).
pub fn column_widths(natural: &[f64], available: f64) -> Vec<f64> {
    if natural.is_empty() {
        return Vec::new();
    }
    let total: f64 = natural.iter().sum();
    if total <= available {
        return natural.to_vec();
    }
    // A fair share each; columns under it keep their natural width.
    let mut fixed = vec![false; natural.len()];
    let mut room = available;
    loop {
        let open = fixed.iter().filter(|&&is_fixed| !is_fixed).count();
        if open == 0 {
            break;
        }
        let share = room / open as f64;
        let mut fixed_any = false;
        for (&width, is_fixed) in natural.iter().zip(&mut fixed) {
            if !*is_fixed && width <= share {
                *is_fixed = true;
                room -= width;
                fixed_any = true;
            }
        }
        if !fixed_any {
            break;
        }
    }
    let open_natural: f64 =
        natural.iter().zip(&fixed).filter(|&(_, &fixed)| !fixed).map(|(&width, _)| width).sum();
    natural
        .iter()
        .zip(fixed)
        .map(|(&width, fixed)| {
            if fixed {
                width
            } else {
                MIN_COLUMN.max((room * width / open_natural.max(1.0)).floor())
            }
        })
        .collect()
}
