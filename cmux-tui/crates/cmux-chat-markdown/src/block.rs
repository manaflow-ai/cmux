//! Blocks: lines, containers (quotes, lists) and leaves (code, headings, rules, tables,
//! paragraphs with leading link reference definitions).

use crate::chars::{
    self, at, collect, contains_grapheme, graphemes, is_space_or_newline, trim_spaces,
};
use crate::{Align, Block, Item, Kind, LinkPolicy, List, Refs, Table, Text, inline, style};

/// Containers nested deeper than this stay literal paragraphs.
const MAX_DEPTH: usize = 32;

/// A source line as Unicode scalars, with column arithmetic (tabs stop every 4 columns).
#[derive(Clone, Debug, Default)]
pub(crate) struct Line {
    s: Vec<char>,
}

/// Lines split at LF, CRLF and CR. A final newline does not add an empty line.
pub(crate) fn split_lines(text: &str) -> Vec<Line> {
    let mut out = Vec::new();
    let mut cur = Vec::new();
    let mut it = text.chars().peekable();
    let mut open = false;
    while let Some(c) = it.next() {
        if c == '\n' || c == '\r' {
            out.push(Line { s: std::mem::take(&mut cur) });
            open = false;
            if c == '\r' && it.peek() == Some(&'\n') {
                it.next();
            }
            continue;
        }
        cur.push(c);
        open = true;
    }
    if open {
        out.push(Line { s: cur });
    }
    out
}

impl Line {
    fn new(s: Vec<char>) -> Self {
        Line { s }
    }

    fn first(&self) -> Option<char> {
        self.s.first().copied()
    }

    fn is_blank(&self) -> bool {
        self.s.iter().all(|&c| c == ' ' || c == '\t')
    }

    /// Columns of leading whitespace.
    fn indent(&self) -> usize {
        let mut col = 0usize;
        for &c in &self.s {
            match c {
                ' ' => col = col.saturating_add(1),
                '\t' => col = col.saturating_add(tab_width(col)),
                _ => break,
            }
        }
        col
    }

    /// The line with `cols` columns of leading whitespace removed (a partly used tab leaves
    /// spaces). Removes at most the leading whitespace.
    fn dropping(&self, cols: usize) -> Line {
        let mut col = 0usize;
        let mut i = 0usize;
        while col < cols {
            match at(&self.s, i) {
                Some(' ') => {
                    col = col.saturating_add(1);
                    i = i.saturating_add(1);
                }
                Some('\t') => {
                    let w = tab_width(col);
                    if col.saturating_add(w) > cols {
                        let rest = col.saturating_add(w).saturating_sub(cols);
                        let mut s = vec![' '; rest];
                        s.extend_from_slice(self.tail(i.saturating_add(1)));
                        return Line::new(s);
                    }
                    col = col.saturating_add(w);
                    i = i.saturating_add(1);
                }
                _ => break,
            }
        }
        Line::new(self.tail(i).to_vec())
    }

    fn tail(&self, from: usize) -> &[char] {
        self.s.get(from..).unwrap_or_default()
    }

    fn drop_first(&self) -> Line {
        Line::new(self.tail(1).to_vec())
    }

    fn trimmed_leading(&self) -> Line {
        let i = self.s.iter().take_while(|&&c| c == ' ' || c == '\t').count();
        Line::new(self.tail(i).to_vec())
    }

    fn string(&self) -> String {
        collect(&self.s)
    }

    fn string_range(&self, lo: usize, hi: usize) -> String {
        let hi = hi.min(self.s.len());
        collect(self.s.get(lo.min(hi)..hi).unwrap_or_default())
    }
}

/// Columns from `col` to the next tab stop (every 4 columns).
fn tab_width(col: usize) -> usize {
    4usize.saturating_sub(col.checked_rem(4).unwrap_or(0))
}

struct Ctx<'a> {
    known: Option<&'a Refs>,
    policy: &'a dyn LinkPolicy,
}

impl Ctx<'_> {
    fn inline(&self, s: &str, breaks: bool) -> Text {
        inline::parse(s, breaks, self.known, self.policy)
    }
}

/// Parse lines of one container into blocks.
pub(crate) fn parse(
    lines: &[Line],
    refs: &mut Refs,
    known: Option<&Refs>,
    top_level: bool,
    depth: usize,
    policy: &dyn LinkPolicy,
) -> Vec<Block> {
    let cx = Ctx { known, policy };
    parse_in(&cx, lines, refs, top_level, depth)
}

struct Out {
    blocks: Vec<Block>,
    blank: bool,
    top_level: bool,
}

impl Out {
    fn add(&mut self, kind: Kind, from: usize, to: usize) {
        let blank_before = self.blank && !self.blocks.is_empty();
        let lines = if self.top_level { (from, to) } else { (0, 0) };
        self.blocks.push(Block { kind, rich: true, blank_before, lines });
        self.blank = false;
    }
}

fn parse_in(
    cx: &Ctx<'_>,
    lines: &[Line],
    refs: &mut Refs,
    top_level: bool,
    depth: usize,
) -> Vec<Block> {
    let mut out = Out { blocks: Vec::new(), blank: false, top_level };
    let mut i = 0usize;
    // Pathological nesting: past MAX_DEPTH, containers stay literal paragraphs.
    let nest = depth < MAX_DEPTH;
    let next_depth = depth.saturating_add(1);
    while let Some(line) = lines.get(i) {
        if line.is_blank() {
            out.blank = true;
            i = i.saturating_add(1);
            continue;
        }
        let start = i;
        let ind = line.indent();
        // Indented code.
        if ind >= 4 {
            let mut body: Vec<Line> = Vec::new();
            while let Some(l) = lines.get(i).filter(|l| l.is_blank() || l.indent() >= 4) {
                body.push(l.dropping(4));
                i = i.saturating_add(1);
            }
            while body.last().is_some_and(Line::is_blank) {
                body.pop();
                i = i.saturating_sub(1);
            }
            let text = join_lines(&body);
            out.add(
                Kind::Code { lang: String::new(), text, fenced: false, closed: true },
                start,
                i,
            );
            continue;
        }
        let t = line.dropping(ind);
        // Fenced code.
        if let Some(f) = fence(&t) {
            let mut body: Vec<Line> = Vec::new();
            let mut closed = false;
            i = i.saturating_add(1);
            while let Some(l) = lines.get(i) {
                if l.indent() < 4
                    && let Some(c) = fence(&l.dropping(l.indent()))
                    && c.ch == f.ch
                    && c.count >= f.count
                    && c.info.is_empty()
                {
                    closed = true;
                    i = i.saturating_add(1);
                    break;
                }
                body.push(l.dropping(ind));
                i = i.saturating_add(1);
            }
            let lang = first_word(&f.info);
            out.add(Kind::Code { lang, text: join_lines(&body), fenced: true, closed }, start, i);
            continue;
        }
        if let Some((level, text)) = atx_heading(&t) {
            i = i.saturating_add(1);
            out.add(Kind::Heading(level, cx.inline(&text, true)), start, i);
            continue;
        }
        if is_rule(&t) {
            i = i.saturating_add(1);
            out.add(Kind::Rule, start, i);
            continue;
        }
        if nest && t.first() == Some('>') {
            let mut inner: Vec<Line> = Vec::new();
            let mut last_paragraph = false;
            while let Some(l) = lines.get(i) {
                let li = l.indent();
                let d = l.dropping(li);
                if li < 4 && d.first() == Some('>') {
                    let mut q = d.drop_first();
                    if q.first() == Some(' ') {
                        q = q.drop_first();
                    } else if q.first() == Some('\t') {
                        q = q.dropping(1);
                    }
                    // Through nested quote markers: lazy lines continue the deepest paragraph.
                    let mut deep = q.dropping(q.indent());
                    while deep.first() == Some('>') {
                        deep = deep.drop_first();
                        deep = deep.dropping(deep.indent());
                    }
                    last_paragraph = !deep.is_blank() && !starts_block(&deep) && q.indent() < 4;
                    inner.push(q);
                    i = i.saturating_add(1);
                } else if last_paragraph && !l.is_blank() && !starts_block(&d) {
                    inner.push(l.clone()); // lazy continuation
                    i = i.saturating_add(1);
                } else {
                    break;
                }
            }
            let blocks = parse_in(cx, &inner, refs, false, next_depth);
            out.add(Kind::Quote(blocks), start, i);
            continue;
        }
        if nest && let Some(m) = list_marker(&t, false) {
            let blank_before_list = out.blank;
            let mut blank_after = false;
            let mut items: Vec<Item> = Vec::new();
            let mut loose = false;
            let mut start_number = m.number;
            let (ordered, delim) = (m.ordered, m.delim);
            while let Some(l) = lines.get(i) {
                let li = l.indent();
                if li >= 4 {
                    break;
                }
                let Some(mk) = list_marker(&l.dropping(li), false) else { break };
                if mk.ordered != ordered || mk.delim != delim {
                    break;
                }
                if items.is_empty() {
                    start_number = mk.number;
                }
                let content_indent = li.saturating_add(mk.width);
                let first_blank = mk.first.is_blank();
                let mut body: Vec<Line> = vec![mk.first];
                i = i.saturating_add(1);
                let mut last_paragraph = !first_blank;
                let mut saw_blank = first_blank;
                let mut inner_blank = false;
                while let Some(l2) = lines.get(i) {
                    if l2.is_blank() {
                        // An item may start with at most one blank line.
                        if body.len() == 1 && body.first().is_some_and(Line::is_blank) {
                            break;
                        }
                        body.push(Line::default());
                        i = i.saturating_add(1);
                        saw_blank = true;
                        last_paragraph = false;
                        continue;
                    }
                    if l2.indent() >= content_indent {
                        if saw_blank && body.iter().any(|b| !b.is_blank()) {
                            inner_blank = true;
                        }
                        saw_blank = false;
                        let d = l2.dropping(content_indent);
                        last_paragraph = !starts_block(&d.dropping(d.indent())) || d.indent() >= 4;
                        body.push(d);
                        i = i.saturating_add(1);
                        continue;
                    }
                    let d2 = l2.dropping(l2.indent());
                    // A list marker below the content column is the next item (or a new list),
                    // never lazy text.
                    if list_marker(&d2, false).is_some() {
                        break;
                    }
                    if !saw_blank && last_paragraph && !starts_block(&d2) {
                        body.push(l2.trimmed_leading()); // lazy continuation
                        i = i.saturating_add(1);
                        continue;
                    }
                    break;
                }
                // Trailing blank lines belong between items, not to this item.
                let mut trailing = 0usize;
                while body.len() > 1 && body.last().is_some_and(Line::is_blank) {
                    body.pop();
                    trailing = trailing.saturating_add(1);
                }
                if inner_blank {
                    loose = true;
                }
                let mut blocks = parse_in(cx, &body, refs, false, next_depth);
                let mut task = None;
                if let Some(first) = blocks.first_mut()
                    && let Kind::Paragraph(p) = &first.kind
                    && let Some((checked, rest)) = task_prefix(p)
                {
                    task = Some(checked);
                    first.kind = Kind::Paragraph(rest);
                }
                items.push(Item { marker: mk.marker, task, blocks });
                if trailing > 0 {
                    // A blank line then another item of this list: loose.
                    let next_item = lines.get(i).is_some_and(|next| {
                        next.indent() < 4
                            && list_marker(&next.dropping(next.indent()), false)
                                .is_some_and(|n| n.ordered == ordered && n.delim == delim)
                    });
                    if next_item {
                        loose = true;
                    } else {
                        blank_after = true;
                        break;
                    }
                }
            }
            out.blank = blank_before_list;
            out.add(Kind::List(List { ordered, start: start_number, loose, items }), start, i);
            out.blank = blank_after;
            continue;
        }
        // Table: a header row, then a delimiter row with the same cell count.
        if is_table(lines, i) {
            let (table, end) = table(cx, lines, i);
            i = end;
            out.add(Kind::Table(table), start, i);
            continue;
        }
        // Paragraph (maybe link reference definitions, maybe a setext heading, maybe ending in
        // a table header).
        let mut para: Vec<Line> = vec![t];
        i = i.saturating_add(1);
        let mut setext = 0u8;
        let mut table_at: Option<usize> = None;
        while let Some(l) = lines.get(i) {
            if l.is_blank() {
                break;
            }
            let li = l.indent();
            let d = l.dropping(li);
            if li < 4
                && let Some(level) = setext_level(&d)
            {
                setext = level;
                i = i.saturating_add(1);
                break;
            }
            if li < 4 && starts_block(&d) {
                break;
            }
            if is_table(lines, i) {
                table_at = Some(i);
                break;
            }
            para.push(d);
            i = i.saturating_add(1);
        }
        // Leading link reference definitions.
        let joined = join_lines(&para);
        let text = definitions(&joined, refs);
        if setext > 0 {
            if !text.is_empty() {
                out.add(Kind::Heading(setext, cx.inline(&text, true)), start, i);
            } else {
                let last = para.last().map(Line::string).unwrap_or_default();
                out.add(Kind::Paragraph(cx.inline(&last, true)), start, i);
            }
        } else if !text.is_empty() {
            let p = cx.inline(&text, true);
            let rich = paragraph_is_rich(&p, &text);
            out.add(Kind::Paragraph(p), start, i);
            if let Some(last) = out.blocks.last_mut() {
                last.rich = rich;
            }
        }
        if let Some(at_line) = table_at
            && is_table(lines, at_line)
        {
            let s2 = i;
            let (table, end) = table(cx, lines, at_line);
            i = end;
            out.add(Kind::Table(table), s2, i);
        }
    }
    out.blocks
}

fn join_lines(lines: &[Line]) -> String {
    let mut s = String::new();
    for (n, l) in lines.iter().enumerate() {
        if n > 0 {
            s.push('\n');
        }
        s.extend(l.s.iter());
    }
    s
}

/// A paragraph is plain when its only runs are bare links (the plain path detects those too)
/// and its display text equals its source apart from whitespace.
pub(crate) fn paragraph_is_rich(t: &Text, source: &str) -> bool {
    if t.spans.iter().any(|s| s.style != style::LINK) {
        return true;
    }
    let squeeze =
        |s: &str| s.chars().filter(|&c| c != ' ' && c != '\t' && c != '\n').collect::<String>();
    !chars::canon_eq(&squeeze(&t.string), &squeeze(source))
}

// MARK: Leaf recognizers

struct Fence {
    ch: char,
    count: usize,
    info: String,
}

fn fence(t: &Line) -> Option<Fence> {
    let c = t.first().filter(|&c| c == '`' || c == '~')?;
    let n = t.s.iter().take_while(|&&x| x == c).count();
    if n < 3 {
        return None;
    }
    let info = trim_spaces(&t.string_range(n, t.s.len())).to_owned();
    if c == '`' && contains_grapheme(&info, "`") {
        return None;
    }
    Some(Fence { ch: c, count: n, info })
}

/// `info.split(separator: " ").first`: the first run of characters other than " ".
fn first_word(info: &str) -> String {
    let mut out = String::new();
    for g in graphemes(info) {
        if g == " " {
            if out.is_empty() {
                continue;
            }
            break;
        }
        out.push_str(g);
    }
    out
}

fn atx_heading(t: &Line) -> Option<(u8, String)> {
    let n = t.s.iter().take_while(|&&c| c == '#').count();
    if !(1..=6).contains(&n) {
        return None;
    }
    if !matches!(at(&t.s, n), None | Some(' ' | '\t')) {
        return None;
    }
    let body = trim_spaces(&t.string_range(n, t.s.len())).to_owned();
    // Closing sequence: spaces then #s at the end (the regex `#+$`, whose `$` also matches
    // before a final line terminator).
    if let Some(cut) = closing_hashes(&body) {
        let before = body.get(..cut).unwrap_or_default();
        let last = graphemes(before).last().copied();
        if before.is_empty() || last == Some(" ") || last == Some("\t") {
            return Some((u8::try_from(n).unwrap_or(1), trim_spaces(before).to_owned()));
        }
    }
    Some((u8::try_from(n).unwrap_or(1), body))
}

/// The byte offset where `#+$` matches in `s`, if it does.
fn closing_hashes(s: &str) -> Option<usize> {
    let mut end = s.len();
    if let Some(c) = s.chars().next_back()
        && chars::is_line_terminator(c)
    {
        end = end.saturating_sub(c.len_utf8());
    }
    let core = s.get(..end)?;
    let run = core.len().saturating_sub(core.trim_end_matches('#').len());
    if run > 0 { Some(end.saturating_sub(run)) } else { None }
}

fn is_rule(t: &Line) -> bool {
    let Some(c) = t.first().filter(|&c| c == '-' || c == '*' || c == '_') else { return false };
    let mut n = 0usize;
    for &x in &t.s {
        if x == c {
            n = n.saturating_add(1);
        } else if x != ' ' && x != '\t' {
            return false;
        }
    }
    n >= 3
}

fn setext_level(t: &Line) -> Option<u8> {
    let c = t.first().filter(|&c| c == '=' || c == '-')?;
    let mut rest = t.s.iter().skip_while(|&&x| x == c);
    if rest.all(|&x| x == ' ' || x == '\t') { Some(if c == '=' { 1 } else { 2 }) } else { None }
}

struct Marker {
    ordered: bool,
    delim: char,
    number: i64,
    marker: String,
    width: usize,
    first: Line,
}

/// A list item marker at the start of `t` (indentation removed).
fn list_marker(t: &Line, interrupts_paragraph: bool) -> Option<Marker> {
    let c = t.first()?;
    let (marker_len, ordered, number, delim) = if c == '-' || c == '+' || c == '*' {
        (1usize, false, 1i64, c)
    } else if c.is_ascii_digit() {
        let j = t.s.iter().take(10).take_while(|c| c.is_ascii_digit()).count();
        if j > 9 {
            return None;
        }
        let d = at(&t.s, j).filter(|&d| d == '.' || d == ')')?;
        let number = t.string_range(0, j).parse::<i64>().unwrap_or(1);
        (j.saturating_add(1), true, number, d)
    } else {
        return None;
    };
    let rest = Line::new(t.tail(marker_len).to_vec());
    if let Some(r) = rest.first()
        && r != ' '
        && r != '\t'
    {
        return None;
    }
    if interrupts_paragraph && (rest.is_blank() || (ordered && number != 1)) {
        return None;
    }
    // Content indent: marker + 1..4 spaces; 5 or more means 1 (the rest is indented code).
    let blank = rest.is_blank();
    let mut sp = if blank { 1 } else { rest.indent() };
    if !(1..=4).contains(&sp) {
        sp = 1;
    }
    let first = if blank { Line::default() } else { rest.dropping(sp) };
    Some(Marker {
        ordered,
        delim,
        number,
        marker: t.string_range(0, marker_len),
        width: marker_len.saturating_add(sp),
        first,
    })
}

/// Whether a line (indentation removed) starts a block that ends a paragraph.
fn starts_block(t: &Line) -> bool {
    if fence(t).is_some() || atx_heading(t).is_some() || is_rule(t) || t.first() == Some('>') {
        return true;
    }
    list_marker(t, true).is_some()
}

fn task_prefix(p: &Text) -> Option<(bool, Text)> {
    let u: Vec<u16> = p.string.encode_utf16().collect();
    let g = |i: usize| u.get(i).copied();
    if u.len() < 3
        || g(0) != Some(91)
        || g(2) != Some(93)
        || !(u.len() == 3 || matches!(g(3), Some(32 | 9 | 10)))
    {
        return None;
    }
    let checked = match g(1) {
        Some(32) => false,
        Some(120 | 88) => true,
        _ => return None,
    };
    let cut = u.len().min(4);
    let string = String::from_utf16_lossy(u.get(cut..).unwrap_or_default());
    let spans = p
        .spans
        .iter()
        .filter_map(|s| {
            let lo = s.location.max(cut);
            let hi = s.location.saturating_add(s.length);
            (hi > lo).then(|| crate::Span {
                location: lo.saturating_sub(cut),
                length: hi.saturating_sub(lo),
                style: s.style,
                link: s.link.clone(),
                image: s.image.clone(),
            })
        })
        .collect();
    Some((checked, Text { string, spans }))
}

// MARK: Tables

fn split_row(line: &Line) -> Vec<String> {
    let mut t = line.dropping(line.indent()).s;
    while matches!(t.last(), Some(' ' | '\t')) {
        t.pop();
    }
    let mut cells = Vec::new();
    let mut cur = String::new();
    let mut i = usize::from(t.first() == Some(&'|'));
    let mut ticks = 0usize; // open code span's backtick count
    while let Some(c) = at(&t, i) {
        let next = at(&t, i.saturating_add(1));
        if c == '\\' && next == Some('|') {
            cur.push('|');
            i = i.saturating_add(2);
            continue;
        }
        if c == '\\'
            && let Some(next) = next
        {
            cur.push(c);
            cur.push(next);
            i = i.saturating_add(2);
            continue;
        }
        if c == '`' {
            let n = t.get(i..).unwrap_or_default().iter().take_while(|&&x| x == '`').count();
            if ticks == 0 {
                if has_closing_ticks(&t, i.saturating_add(n), n) {
                    ticks = n;
                }
            } else if n == ticks {
                ticks = 0;
            }
            cur.extend(std::iter::repeat_n('`', n));
            i = i.saturating_add(n);
            continue;
        }
        if c == '|' && ticks == 0 {
            cells.push(trim_spaces(&cur).to_owned());
            cur.clear();
            i = i.saturating_add(1);
            continue;
        }
        cur.push(c);
        i = i.saturating_add(1);
    }
    let last = trim_spaces(&cur).to_owned();
    let escaped_end = t.len() >= 2 && at(&t, t.len().saturating_sub(2)) == Some('\\');
    if !last.is_empty() || t.last() != Some(&'|') || escaped_end {
        cells.push(last);
    }
    cells
}

fn has_closing_ticks(t: &[char], from: usize, count: usize) -> bool {
    closing_ticks(t, from, count).is_some()
}

/// The index of the next run of exactly `count` backticks at or after `from`.
pub(crate) fn closing_ticks(t: &[char], from: usize, count: usize) -> Option<usize> {
    let mut i = from;
    while let Some(c) = at(t, i) {
        if c == '`' {
            let n = t.get(i..).unwrap_or_default().iter().take_while(|&&x| x == '`').count();
            if n == count {
                return Some(i);
            }
            i = i.saturating_add(n);
        } else {
            i = i.saturating_add(1);
        }
    }
    None
}

fn delimiter_row(line: &Line) -> Option<Vec<Align>> {
    if line.indent() >= 4 {
        return None;
    }
    let t = line.dropping(line.indent());
    if !t.s.contains(&'-') || !t.s.iter().all(|&c| matches!(c, '|' | '-' | ':' | ' ' | '\t')) {
        return None;
    }
    let cells = split_row(line);
    if cells.is_empty() {
        return None;
    }
    let mut aligns = Vec::with_capacity(cells.len());
    for c in &cells {
        let s = trim_spaces(c);
        if s.is_empty() || !s.chars().all(|c| c == '-' || c == ':') || !s.contains('-') {
            return None;
        }
        let core = s.trim_matches(':');
        if core.is_empty() || !core.chars().all(|c| c == '-') {
            return None;
        }
        let (l, r) = (s.starts_with(':'), s.ends_with(':'));
        aligns.push(match (l, r) {
            (true, true) => Align::Center,
            (false, true) => Align::Right,
            (true, false) => Align::Left,
            (false, false) => Align::None,
        });
    }
    // A single column needs a pipe (else "---" is a setext underline or a rule).
    if cells.len() == 1 && !t.s.contains(&'|') {
        return None;
    }
    Some(aligns)
}

/// Whether a table starts at line `i`: a header row with a pipe, then a delimiter row with the
/// same cell count.
fn is_table(lines: &[Line], i: usize) -> bool {
    table_head(lines, i).is_some()
}

fn table_head(lines: &[Line], i: usize) -> Option<(Vec<String>, Vec<Align>)> {
    let h = lines.get(i)?;
    let below = lines.get(i.saturating_add(1))?;
    if h.indent() >= 4 || !h.s.contains(&'|') {
        return None;
    }
    let aligns = delimiter_row(below)?;
    let header = split_row(h);
    (header.len() == aligns.len()).then_some((header, aligns))
}

/// The table at line `i` (`is_table` holds) and the line after it.
fn table(cx: &Ctx<'_>, lines: &[Line], i: usize) -> (Table, usize) {
    let Some((header, aligns)) = table_head(lines, i) else {
        return (Table { aligns: Vec::new(), header: Vec::new(), rows: Vec::new() }, i);
    };
    let mut rows: Vec<Vec<Text>> = Vec::new();
    let mut cols = aligns.len();
    let mut j = i.saturating_add(2);
    while let Some(l) = lines.get(j) {
        if l.is_blank() || (l.indent() < 4 && starts_block(&l.dropping(l.indent()))) {
            break;
        }
        let cells: Vec<Text> = split_row(l).iter().map(|c| cx.inline(c, false)).collect();
        cols = cols.max(cells.len());
        rows.push(cells);
        j = j.saturating_add(1);
    }
    // Rows keep every cell: missing cells are empty, extra cells add columns (no data lost).
    let mut al = aligns;
    al.resize(cols.max(al.len()), Align::None);
    let mut head: Vec<Text> = header.iter().map(|c| cx.inline(c, false)).collect();
    head.resize(cols.max(head.len()), Text::default());
    for r in &mut rows {
        r.resize(cols.max(r.len()), Text::default());
    }
    (Table { aligns: al, header: head, rows }, j)
}

// MARK: Link reference definitions

/// Removes leading `[label]: dest "title"` definitions from a paragraph's text.
fn definitions(text: &str, refs: &mut Refs) -> String {
    if !text.starts_with('[') {
        return text.to_owned();
    }
    let g = graphemes(text);
    let is = |k: usize, s: &str| g.get(k).is_some_and(|x| *x == s);
    let find = |from: usize, pred: &dyn Fn(&str) -> bool| -> Option<usize> {
        g.get(from..)
            .unwrap_or_default()
            .iter()
            .position(|x| pred(x))
            .map(|p| p.saturating_add(from))
    };
    let join =
        |lo: usize, hi: usize| -> String { g.get(lo..hi.max(lo)).unwrap_or_default().concat() };
    let end = g.len();
    let mut r = 0usize;
    while is(r, "[") {
        let Some(close) = find(r, &|x| x == "]") else { break };
        if !is(close.saturating_add(1), ":") {
            break;
        }
        let label = join(r.saturating_add(1), close);
        if label.chars().all(is_space_or_newline)
            || g.get(r.saturating_add(1)..close).is_some_and(|l| l.contains(&"["))
        {
            break;
        }
        let mut j = close.saturating_add(2);
        while is(j, " ") || is(j, "\t") || is(j, "\n") {
            j = j.saturating_add(1);
        }
        let dest;
        if is(j, "<") {
            let Some(e) = find(j, &|x| x == ">") else { break };
            dest = join(j.saturating_add(1), e);
            j = e.saturating_add(1);
        } else {
            let e = find(j, &|x| x == " " || x == "\n" || x == "\t").unwrap_or(end);
            dest = join(j, e);
            j = e;
        }
        if dest.is_empty() {
            break;
        }
        // Optional title on the same line; then the line must end.
        let mut title = None;
        let mut k = j;
        while is(k, " ") || is(k, "\t") {
            k = k.saturating_add(1);
        }
        let q = match g.get(k) {
            Some(&"\"") => Some("\""),
            Some(&"'") => Some("'"),
            Some(&"(") => Some(")"),
            _ => None,
        };
        if let Some(q) = q
            && let Some(e) = find(k.saturating_add(1), &|x| x == q)
        {
            title = Some(join(k.saturating_add(1), e));
            k = e.saturating_add(1);
        }
        while is(k, " ") || is(k, "\t") {
            k = k.saturating_add(1);
        }
        if !(k >= end || is(k, "\n")) {
            break;
        }
        refs.insert_first(Refs::normalize(&label), (inline::unescape(&dest), title));
        r = if k >= end { end } else { k.saturating_add(1) };
    }
    join(r, end)
}
