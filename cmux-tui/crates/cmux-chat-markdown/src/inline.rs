//! CommonMark inline parsing: code spans, escapes, entities, autolinks (angle and GFM extended,
//! recognised before emphasis so `_` in a URL is never emphasis), links and images with the
//! bracket stack, then emphasis and strikethrough with the delimiter-run algorithm (flanking
//! rules, rule of 3, openers bottom).

use std::collections::HashMap;

use crate::block::closing_ticks;
use crate::chars::{
    at, canon_eq_opt, collect, grapheme_is_letter, grapheme_is_number, graphemes, is_alnum,
    is_ascii_punct, is_line_terminator, is_punct, is_ws,
};
use crate::{LinkPolicy, Refs, Span, Text, sanitize, style};

#[derive(Clone, Debug)]
enum Node {
    Text(String),
    /// Code or an autolink: text, style, link.
    Styled(String, u16, Option<String>),
    /// An image placeholder (never loaded): text, link, source.
    Image(String, Option<String>, String),
    Delim(char, usize),
    Open(u16),
    Close(u16),
    LinkOpen(String),
    LinkClose,
    Br,
}

#[derive(Clone, Copy, Debug)]
struct Delim {
    node: usize,
    ch: char,
    count: usize,
    orig: usize,
    can_open: bool,
    can_close: bool,
}

#[derive(Clone, Copy, Debug)]
struct Bracket {
    node: usize,
    image: bool,
    active: bool,
    delim_bottom: usize,
    pos: usize,
}

pub(crate) fn parse(s: &str, breaks: bool, refs: Option<&Refs>, policy: &dyn LinkPolicy) -> Text {
    let src: Vec<char> = s.chars().collect();
    let mut nodes: Vec<Node> = Vec::new();
    let mut delims: Vec<Delim> = Vec::new();
    let mut brackets: Vec<Bracket> = Vec::new();
    let mut text: Vec<char> = Vec::new();
    let mut i = 0usize;
    let flush = |nodes: &mut Vec<Node>, text: &mut Vec<char>| {
        if !text.is_empty() {
            nodes.push(Node::Text(collect(text)));
            text.clear();
        }
    };
    let prev = |i: usize| i.checked_sub(1).and_then(|p| at(&src, p));

    while let Some(c) = at(&src, i) {
        let next = at(&src, i.saturating_add(1));
        match c {
            '\\' => {
                if let Some(n) = next.filter(|&n| is_ascii_punct(n)) {
                    text.push(n);
                    i = i.saturating_add(2);
                    continue;
                }
                if next == Some('\n') {
                    flush(&mut nodes, &mut text);
                    nodes.push(Node::Br);
                    i = i.saturating_add(2);
                    continue;
                }
                text.push(c);
                i = i.saturating_add(1);
            }
            '`' => {
                let n = run(&src, i, '`');
                let from = i.saturating_add(n);
                if let Some(end) = closing_ticks(&src, from, n) {
                    flush(&mut nodes, &mut text);
                    let body: String = src
                        .get(from..end)
                        .unwrap_or_default()
                        .iter()
                        .map(|&x| if x == '\n' { ' ' } else { x })
                        .collect();
                    nodes.push(Node::Styled(strip_code_space(body), style::CODE, None));
                    i = end.saturating_add(n);
                } else {
                    text.extend(std::iter::repeat_n('`', n));
                    i = from;
                }
            }
            '&' => {
                if let Some((rep, len)) = entity(&src, i) {
                    text.push(rep);
                    i = i.saturating_add(len);
                } else {
                    text.push(c);
                    i = i.saturating_add(1);
                }
            }
            '<' => {
                // An autolink whose URL the policy refuses stays literal text, brackets included.
                if let Some((url, len, label)) = angle_autolink(&src, i)
                    && let Some(safe) = sanitize(policy, &url)
                {
                    flush(&mut nodes, &mut text);
                    nodes.push(Node::Styled(label, style::LINK, Some(safe)));
                    i = i.saturating_add(len);
                } else {
                    text.push(c);
                    i = i.saturating_add(1);
                }
            }
            '\n' => {
                flush(&mut nodes, &mut text);
                if breaks {
                    nodes.push(Node::Br);
                } else {
                    text.push(' ');
                }
                i = i.saturating_add(1);
                while matches!(at(&src, i), Some(' ' | '\t')) {
                    i = i.saturating_add(1);
                }
            }
            '*' | '_' | '~' => {
                let n = run(&src, i, c);
                if c == '~' && n > 2 {
                    text.extend(std::iter::repeat_n(c, n));
                    i = i.saturating_add(n);
                    continue;
                }
                let before = prev(i);
                let after = at(&src, i.saturating_add(n));
                let b_ws = before.is_none_or(is_ws);
                let a_ws = after.is_none_or(is_ws);
                let b_p = before.is_some_and(is_punct);
                let a_p = after.is_some_and(is_punct);
                let left = !a_ws && (!a_p || b_ws || b_p);
                let right = !b_ws && (!b_p || a_ws || a_p);
                let (mut can_open, mut can_close) = (left, right);
                if c == '_' {
                    can_open = left && (!right || b_p);
                    can_close = right && (!left || a_p);
                }
                flush(&mut nodes, &mut text);
                nodes.push(Node::Delim(c, n));
                if can_open || can_close {
                    let node = nodes.len().saturating_sub(1);
                    delims.push(Delim { node, ch: c, count: n, orig: n, can_open, can_close });
                }
                i = i.saturating_add(n);
            }
            '!' if next == Some('[') => {
                flush(&mut nodes, &mut text);
                nodes.push(Node::Text("![".to_owned()));
                let node = nodes.len().saturating_sub(1);
                let pos = i.saturating_add(2);
                brackets.push(Bracket {
                    node,
                    image: true,
                    active: true,
                    delim_bottom: delims.len(),
                    pos,
                });
                i = pos;
            }
            '[' => {
                flush(&mut nodes, &mut text);
                nodes.push(Node::Text("[".to_owned()));
                let node = nodes.len().saturating_sub(1);
                let pos = i.saturating_add(1);
                brackets.push(Bracket {
                    node,
                    image: false,
                    active: true,
                    delim_bottom: delims.len(),
                    pos,
                });
                i = pos;
            }
            ']' => {
                let Some(b) = brackets.pop().filter(|b| b.active) else {
                    text.push(c);
                    i = i.saturating_add(1);
                    continue;
                };
                flush(&mut nodes, &mut text);
                let mut dest: Option<String> = None;
                let mut end = i.saturating_add(1);
                if let Some((d, e)) = inline_link_tail(&src, i.saturating_add(1)) {
                    dest = Some(d);
                    end = e;
                } else if let Some(refs) = refs {
                    // [text][label], [text][], [text]
                    let inner = collect(src.get(b.pos..i.max(b.pos)).unwrap_or_default());
                    let label_from = i.saturating_add(2);
                    let close = src
                        .get(label_from..)
                        .and_then(|t| t.iter().position(|&x| x == ']'))
                        .map(|p| p.saturating_add(label_from));
                    if next == Some('[')
                        && let Some(close) = close
                    {
                        let label = collect(src.get(label_from..close).unwrap_or_default());
                        let key = Refs::normalize(if label.is_empty() { &inner } else { &label });
                        if let Some(r) = refs.get(&key) {
                            dest = Some(r.0.clone());
                            end = close.saturating_add(1);
                        }
                    } else if let Some(r) = refs.get(&Refs::normalize(&inner)) {
                        dest = Some(r.0.clone());
                    }
                }
                let Some(dest) = dest else {
                    text.push(c);
                    i = i.saturating_add(1);
                    continue;
                };
                // Emphasis inside the link text, then wrap it.
                process_emphasis(&mut nodes, &mut delims, b.delim_bottom);
                let safe = sanitize(policy, &dest);
                if b.image {
                    // Never loaded: the text "[Image: alt]", a link when the URL is allowed. The
                    // source goes to the host's image provider only.
                    let alt = plain(nodes.get(b.node.saturating_add(1)..).unwrap_or_default());
                    nodes.truncate(b.node);
                    nodes.push(Node::Image(policy.image_placeholder(&alt), safe, dest));
                    brackets.retain(|x| x.node <= b.node);
                } else {
                    // A refused URL: the link text stays, as plain text (no link, no target).
                    if let Some(safe) = safe {
                        if let Some(n) = nodes.get_mut(b.node) {
                            *n = Node::LinkOpen(safe);
                        }
                        nodes.push(Node::LinkClose);
                    } else if let Some(n) = nodes.get_mut(b.node) {
                        *n = Node::Text(String::new());
                    }
                    // No links inside links (a refused link is still a link for this rule).
                    brackets.retain(|x| x.node <= b.node);
                    for x in &mut brackets {
                        if !x.image {
                            x.active = false;
                        }
                    }
                }
                i = end;
            }
            _ => {
                // GFM extended autolinks at a word start: www., http://, https://, mailto-less
                // emails.
                if matches!(c, 'w' | 'h' | 'W' | 'H')
                    && prev(i)
                        .is_none_or(|p| is_ws(p) || matches!(p, '(' | '*' | '_' | '~' | '"' | '\''))
                    && let Some((url, len)) = extended_autolink(&src, i)
                    && let Some(safe) = sanitize(policy, &url)
                {
                    flush(&mut nodes, &mut text);
                    let shown = collect(src.get(i..i.saturating_add(len)).unwrap_or_default());
                    nodes.push(Node::Styled(shown, style::LINK, Some(safe)));
                    i = i.saturating_add(len);
                    continue;
                }
                if c == '@'
                    && let Some((local_len, len)) = email_autolink(&src, i, &text)
                {
                    let domain = collect(
                        src.get(i.saturating_add(1)..i.saturating_add(len)).unwrap_or_default(),
                    );
                    if sanitize(policy, &format!("mailto:x@{domain}")).is_some() {
                        // Pull the local part back out of the pending text.
                        let keep = text.len().saturating_sub(local_len);
                        let mut addr = collect(text.get(keep..).unwrap_or_default());
                        addr.push('@');
                        addr.push_str(&domain);
                        text.truncate(keep);
                        flush(&mut nodes, &mut text);
                        let link = format!("mailto:{addr}");
                        nodes.push(Node::Styled(addr, style::LINK, Some(link)));
                        i = i.saturating_add(len);
                        continue;
                    }
                }
                text.push(c);
                i = i.saturating_add(1);
            }
        }
    }
    flush(&mut nodes, &mut text);
    process_emphasis(&mut nodes, &mut delims, 0);
    trim_line_ends(flatten(&nodes))
}

/// The length of the run of `c` at `i`.
fn run(s: &[char], i: usize, c: char) -> usize {
    s.get(i..).unwrap_or_default().iter().take_while(|&&x| x == c).count()
}

/// A code span's one leading and trailing space go when both are there and the span is not all
/// spaces.
fn strip_code_space(code: String) -> String {
    if !(code.starts_with(' ') && code.ends_with(' ') && code.chars().any(|c| c != ' ')) {
        return code;
    }
    let g = graphemes(&code);
    if g.len() >= 2 && g.first() == Some(&" ") && g.last() == Some(&" ") {
        return code.get(1..code.len().saturating_sub(1)).unwrap_or_default().to_owned();
    }
    code
}

// MARK: Emphasis

fn process_emphasis(nodes: &mut Vec<Node>, delims: &mut Vec<Delim>, bottom: usize) {
    // Openers bottom per (char, closer can open, closer count % 3).
    let mut bottoms: HashMap<(char, bool, usize), usize> = HashMap::new();
    let mut ci = bottom;
    while let Some(closer) = delims.get(ci).copied() {
        if !closer.can_close || closer.count == 0 {
            ci = ci.saturating_add(1);
            continue;
        }
        let key = (closer.ch, closer.can_open, closer.orig % 3);
        let floor = bottom.max(bottoms.get(&key).copied().unwrap_or(bottom));
        let mut found = None;
        let mut oi = ci;
        while oi > floor {
            oi = oi.saturating_sub(1);
            let Some(o) = delims.get(oi) else { break };
            if o.ch == closer.ch && o.can_open && o.count > 0 {
                if closer.ch == '~' {
                    if o.count == closer.count {
                        found = Some(oi);
                        break;
                    }
                } else {
                    let sum = o.orig.saturating_add(closer.orig);
                    let odd = (o.can_close || closer.can_open)
                        && sum % 3 == 0
                        && !(o.orig % 3 == 0 && closer.orig % 3 == 0);
                    if !odd {
                        found = Some(oi);
                        break;
                    }
                }
            }
        }
        let Some(found) = found else {
            bottoms.insert(key, ci);
            ci = ci.saturating_add(1);
            continue;
        };
        let opener_count = delims.get(found).map_or(0, |d| d.count);
        let (used, mark) = if closer.ch == '~' {
            (closer.count, style::STRIKE)
        } else if opener_count >= 2 && closer.count >= 2 {
            (2, style::STRONG)
        } else {
            (1, style::EMPHASIS)
        };
        if let Some(d) = delims.get_mut(found) {
            d.count = d.count.saturating_sub(used);
        }
        if let Some(d) = delims.get_mut(ci) {
            d.count = d.count.saturating_sub(used);
        }
        // Marks: inner first. After the opener's node, before the closer's node.
        if let Some(n) = delims.get(found).map(|d| d.node) {
            insert_mark(nodes, delims, n.saturating_add(1), Node::Open(mark));
        }
        if let Some(n) = delims.get(ci).map(|d| d.node) {
            insert_mark(nodes, delims, n, Node::Close(mark));
        }
        // Delimiters between them are literal.
        for d in delims.get_mut(found.saturating_add(1)..ci).unwrap_or_default() {
            d.can_open = false;
            d.can_close = false;
        }
        if let Some(d) = delims.get_mut(found)
            && d.count == 0
        {
            d.can_open = false;
        }
        if delims.get(ci).is_some_and(|d| d.count == 0) {
            ci = ci.saturating_add(1);
        }
    }
    // What matching left of each run prints as literal characters.
    for d in delims.get(bottom..).unwrap_or_default() {
        if let Some(n) = nodes.get_mut(d.node) {
            *n = Node::Delim(d.ch, d.count);
        }
    }
    delims.truncate(bottom);
}

/// Inserts a node at `at`, shifting the node index of every delimiter at or after it. An
/// insertion point outside the nodes inserts nothing.
fn insert_mark(nodes: &mut Vec<Node>, delims: &mut [Delim], at: usize, m: Node) {
    if at > nodes.len() {
        return;
    }
    nodes.insert(at, m);
    for d in delims.iter_mut() {
        if d.node >= at {
            d.node = d.node.saturating_add(1);
        }
    }
}

// MARK: Flatten

struct Flat {
    out: String,
    spans: Vec<Span>,
    len16: usize,
    run_start: usize,
    run_style: u16,
    run_link: Option<String>,
    run_image: Option<String>,
}

impl Flat {
    fn cut(&mut self) {
        if self.len16 > self.run_start && (self.run_style != 0 || self.run_link.is_some()) {
            self.spans.push(Span {
                location: self.run_start,
                length: self.len16.saturating_sub(self.run_start),
                style: self.run_style,
                link: self.run_link.clone(),
                image: self.run_image.clone(),
            });
        }
        self.run_start = self.len16;
    }

    fn set(&mut self, s: u16, l: Option<&str>, image: Option<&str>) {
        if s != self.run_style
            || !canon_eq_opt(l, self.run_link.as_deref())
            || !canon_eq_opt(image, self.run_image.as_deref())
        {
            self.cut();
            self.run_style = s;
            self.run_link = l.map(str::to_owned);
            self.run_image = image.map(str::to_owned);
        }
    }

    fn emit(&mut self, s: &str) {
        self.out.push_str(s);
        self.len16 = self.len16.saturating_add(crate::chars::utf16_len(s));
    }
}

fn flatten(nodes: &[Node]) -> Text {
    let mut f = Flat {
        out: String::new(),
        spans: Vec::new(),
        len16: 0,
        run_start: 0,
        run_style: 0,
        run_link: None,
        run_image: None,
    };
    let mut style_now = 0u16;
    let mut counts: HashMap<u16, i64> = HashMap::new();
    let mut links: Vec<String> = Vec::new();
    for n in nodes {
        let link_now = links.last().map(String::as_str);
        match n {
            Node::Text(s) => {
                f.set(style_now, link_now, None);
                f.emit(s);
            }
            Node::Styled(s, st, l) => {
                f.set(style_now | st, l.as_deref().or(link_now), None);
                f.emit(s);
            }
            Node::Image(s, l, src) => {
                let l2 = l.as_deref().or(link_now);
                let st = if l2.is_some() { style::IMAGE | style::LINK } else { style::IMAGE };
                f.set(style_now | st, l2, Some(src));
                f.emit(s);
            }
            Node::Delim(ch, count) => {
                if *count > 0 {
                    f.set(style_now, link_now, None);
                    let s: String = std::iter::repeat_n(*ch, *count).collect();
                    f.emit(&s);
                }
            }
            Node::Open(s) => {
                let c = counts.entry(*s).or_insert(0);
                *c = c.saturating_add(1);
                style_now |= s;
            }
            Node::Close(s) => {
                let c = counts.entry(*s).or_insert(0);
                *c = c.saturating_sub(1);
                if *c <= 0 {
                    style_now &= !s;
                }
            }
            Node::LinkOpen(d) => {
                links.push(d.clone());
                style_now |= style::LINK;
            }
            Node::LinkClose => {
                links.pop();
                if links.is_empty() {
                    style_now &= !style::LINK;
                }
            }
            Node::Br => {
                f.set(style_now, link_now, None);
                f.emit("\n");
            }
        }
    }
    f.cut();
    Text { string: f.out, spans: merge(f.spans) }
}

fn merge(spans: Vec<Span>) -> Vec<Span> {
    let mut out: Vec<Span> = Vec::with_capacity(spans.len());
    for x in spans {
        if let Some(l) = out.last_mut()
            && l.location.saturating_add(l.length) == x.location
            && l.style == x.style
            && canon_eq_opt(l.link.as_deref(), x.link.as_deref())
            && canon_eq_opt(l.image.as_deref(), x.image.as_deref())
        {
            l.length = l.length.saturating_add(x.length);
        } else {
            out.push(x);
        }
    }
    out
}

/// Trailing spaces of a line are not drawn (hard breaks are "\n"): spaces before each "\n" and
/// at both ends go, and the spans move with the text.
fn trim_line_ends(t: Text) -> Text {
    let s = &t.string;
    if !(s.contains(" \n") || s.ends_with(' ') || s.starts_with(' ')) {
        return t;
    }
    let g = graphemes(s);
    let applies = g.windows(2).any(|w| w.first() == Some(&" ") && w.get(1) == Some(&"\n"))
        || g.last() == Some(&" ")
        || g.first() == Some(&" ");
    if !applies {
        return t;
    }
    let u: Vec<u16> = s.encode_utf16().collect();
    let mut keep = vec![true; u.len()];
    for (k, x) in keep.iter_mut().zip(&u).rev() {
        if *x != 32 {
            break;
        }
        *k = false;
    }
    for (k, x) in keep.iter_mut().zip(&u) {
        if *x != 32 {
            break;
        }
        *k = false;
    }
    let mut j = 0usize;
    while j < u.len() {
        if u.get(j) == Some(&10) {
            let mut y = j;
            while y > 0 && u.get(y.saturating_sub(1)) == Some(&32) {
                y = y.saturating_sub(1);
                if let Some(k) = keep.get_mut(y) {
                    *k = false;
                }
            }
        }
        j = j.saturating_add(1);
    }
    let mut map: Vec<usize> = Vec::with_capacity(u.len().saturating_add(1));
    let mut out: Vec<u16> = Vec::with_capacity(u.len());
    for (x, kept) in u.iter().zip(&keep) {
        map.push(out.len());
        if *kept {
            out.push(*x);
        }
    }
    map.push(out.len());
    let spans = t
        .spans
        .into_iter()
        .filter_map(|sp| {
            let a = *map.get(sp.location)?;
            let b = *map.get(sp.location.checked_add(sp.length)?)?;
            (b > a).then(|| Span { location: a, length: b.saturating_sub(a), ..sp })
        })
        .collect();
    Text { string: String::from_utf16_lossy(&out), spans }
}

fn plain(ns: &[Node]) -> String {
    let mut s = String::new();
    for n in ns {
        match n {
            Node::Text(t) | Node::Styled(t, _, _) | Node::Image(t, _, _) => s.push_str(t),
            Node::Delim(c, n) => s.extend(std::iter::repeat_n(*c, *n)),
            Node::Br => s.push(' '),
            _ => {}
        }
    }
    s
}

// MARK: Pieces

const ENTITIES: &[(&str, char)] = &[
    ("amp", '&'),
    ("lt", '<'),
    ("gt", '>'),
    ("quot", '"'),
    ("apos", '\''),
    ("nbsp", '\u{00A0}'),
    ("copy", '©'),
    ("reg", '®'),
    ("trade", '™'),
    ("hellip", '…'),
    ("mdash", '—'),
    ("ndash", '–'),
    ("lsquo", '‘'),
    ("rsquo", '’'),
    ("ldquo", '“'),
    ("rdquo", '”'),
    ("bull", '•'),
    ("middot", '·'),
    ("times", '×'),
    ("divide", '÷'),
    ("deg", '°'),
    ("plusmn", '±'),
    ("larr", '←'),
    ("rarr", '→'),
    ("uarr", '↑'),
    ("darr", '↓'),
    ("harr", '↔'),
    ("check", '✓'),
    ("euro", '€'),
    ("pound", '£'),
    ("yen", '¥'),
    ("cent", '¢'),
    ("sect", '§'),
    ("para", '¶'),
    ("laquo", '«'),
    ("raquo", '»'),
    ("le", '≤'),
    ("ge", '≥'),
    ("ne", '≠'),
    ("infin", '∞'),
];

/// An entity at `i` ("&name;", "&#123;", "&#x7B;"): its character and length.
fn entity(s: &[char], i: usize) -> Option<(char, usize)> {
    let from = i.saturating_add(1);
    let window = s.get(from..)?;
    let semi = window.iter().take(34).position(|&c| c == ';')?.saturating_add(from);
    let body = collect(s.get(from..semi)?);
    let len = semi.saturating_sub(i).saturating_add(1);
    let g = graphemes(&body);
    if g.first() == Some(&"#") {
        let hex = matches!(g.get(1), Some(&"x" | &"X"));
        let digits = g.get(if hex { 2 } else { 1 }..).unwrap_or_default().concat();
        let v = parse_u32(&digits, hex)?;
        let scalar = if v == 0 { None } else { char::from_u32(v) };
        return Some((scalar.unwrap_or('\u{FFFD}'), len));
    }
    ENTITIES.iter().find(|(name, _)| *name == body).map(|&(_, c)| (c, len))
}

/// Swift's `UInt32(digits, radix:)` for at most 7 decimal or 6 hex characters: an optional
/// sign, then digits.
fn parse_u32(digits: &str, hex: bool) -> Option<u32> {
    let n = digits.chars().count();
    if n == 0 || n > if hex { 6 } else { 7 } {
        return None;
    }
    let (negative, body) = match digits.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, digits.strip_prefix('+').unwrap_or(digits)),
    };
    if body.is_empty() {
        return None;
    }
    let v = u32::from_str_radix(body, if hex { 16 } else { 10 }).ok()?;
    if body.starts_with(['+', '-']) || (negative && v != 0) {
        return None;
    }
    Some(v)
}

/// `<scheme:...>` or `<email>` at `i`: (url, length, label).
fn angle_autolink(s: &[char], i: usize) -> Option<(String, usize, String)> {
    let from = i.saturating_add(1);
    let end = s.get(from..)?.iter().take(2048).position(|&c| c == '>')?.saturating_add(from);
    let body = collect(s.get(from..end)?);
    let len = end.saturating_sub(i).saturating_add(1);
    let g = graphemes(&body);
    if g.is_empty() || g.iter().any(|x| *x == " " || *x == "<" || *x == "\n") {
        return None;
    }
    if let Some(colon) = g.iter().position(|x| *x == ":") {
        let scheme = g.get(..colon)?;
        if !(2..=32).contains(&scheme.len())
            || !scheme.first().is_some_and(|x| grapheme_is_letter(x))
            || !scheme.iter().all(|x| {
                grapheme_is_letter(x) || grapheme_is_number(x) || matches!(*x, "+" | "." | "-")
            })
        {
            return None;
        }
        return Some((body.clone(), len, body));
    }
    if body.contains('@') && is_email(&body) {
        return Some((format!("mailto:{body}"), len, body));
    }
    None
}

/// `^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@label(\.label)*$` with labels of 1 to 63 letters, digits
/// and inner hyphens; `$` also matches before a final line terminator.
fn is_email(body: &str) -> bool {
    let mut s = body;
    if let Some(c) = s.chars().next_back()
        && is_line_terminator(c)
    {
        s = s.get(..s.len().saturating_sub(c.len_utf8())).unwrap_or_default();
    }
    let Some((local, domain)) = s.split_once('@') else { return false };
    let local_ok = !local.is_empty()
        && local.chars().all(|c| c.is_ascii_alphanumeric() || ".!#$%&'*+/=?^_`{|}~-".contains(c));
    local_ok
        && domain.split('.').all(|l| {
            let b = l.as_bytes();
            (1..=63).contains(&b.len())
                && b.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'-')
                && b.first().is_some_and(u8::is_ascii_alphanumeric)
                && b.last().is_some_and(u8::is_ascii_alphanumeric)
        })
}

/// GFM extended autolink at `i`: "www." or "http(s)://", a valid domain, then anything up to
/// whitespace or "<", minus trailing punctuation, an unbalanced ")" and a trailing entity-like
/// "&x;". Returns (url, length).
pub(crate) fn extended_autolink(s: &[char], i: usize) -> Option<(String, usize)> {
    let has = |p: &str| {
        let tail = s.get(i..).unwrap_or_default();
        p.chars().count() <= tail.len() && p.chars().zip(tail).all(|(b, a)| lower_eq(*a, b))
    };
    let (start, prefix) = if has("https://") {
        (i.saturating_add(8), "")
    } else if has("http://") {
        (i.saturating_add(7), "")
    } else if has("www.") {
        (i, "http://")
    } else {
        return None;
    };
    // Domain: alphanumerics, "-", "_", "."; at least one "."; no "_" in the last two labels.
    let mut j = start;
    while is_alnum(at(s, j)) || matches!(at(s, j), Some('-' | '_' | '.')) {
        j = j.saturating_add(1);
    }
    let domain = collect(s.get(start..j).unwrap_or_default());
    let g = graphemes(&domain);
    let labels: Vec<&[&str]> = g.split(|x| *x == ".").collect();
    let port = at(s, j) == Some(':');
    let last_two = labels.get(labels.len().saturating_sub(2)..).unwrap_or_default();
    if domain.is_empty() || g.first() == Some(&".") || last_two.iter().any(|l| l.contains(&"_")) {
        return None;
    }
    if (labels.len() < 2 || labels.last().is_none_or(|l| l.is_empty()))
        && !(prefix.is_empty() && (domain == "localhost" || port))
    {
        // "www." needs a real domain; "http://" also takes localhost and a host with a port.
        return None;
    }
    while at(s, j).is_some_and(|c| !is_ws(c) && c != '<') {
        j = j.saturating_add(1);
    }
    let mut end = j;
    // Trailing punctuation and unbalanced parentheses.
    while end > start {
        let Some(c) = at(s, end.saturating_sub(1)) else { break };
        if "?!.,:*_~'\"".contains(c) {
            end = end.saturating_sub(1);
            continue;
        }
        if c == ')' {
            let span = s.get(i..end).unwrap_or_default();
            let open = span.iter().filter(|&&x| x == '(').count();
            let close = span.iter().filter(|&&x| x == ')').count();
            if close > open {
                end = end.saturating_sub(1);
                continue;
            }
        }
        if c == ';'
            && let Some(mut k) = end.checked_sub(2)
        {
            while k > start && is_alnum(at(s, k)) {
                k = k.saturating_sub(1);
            }
            if k >= start && at(s, k) == Some('&') {
                end = k;
                continue;
            }
        }
        break;
    }
    if end <= start {
        return None;
    }
    let raw = collect(s.get(i..end).unwrap_or_default());
    Some((format!("{prefix}{raw}"), end.saturating_sub(i)))
}

/// `Character(a).lowercased() == Character(b).lowercased()`.
fn lower_eq(a: char, b: char) -> bool {
    a == b || a.to_lowercase().eq(b.to_lowercase())
}

/// An email at "@" position `i`: the local part is the tail of the pending text. Returns (local
/// part length, length from "@").
fn email_autolink(s: &[char], i: usize, tail: &[char]) -> Option<(usize, usize)> {
    let mut k = tail.len();
    while let Some(p) = k.checked_sub(1)
        && let Some(c) = at(tail, p)
        && (is_alnum(Some(c)) || ".-_+".contains(c))
    {
        k = p;
    }
    let local_len = tail.len().saturating_sub(k);
    if local_len == 0 {
        return None;
    }
    if let Some(p) = k.checked_sub(1)
        && !at(tail, p).is_some_and(|c| is_ws(c) || c == '(')
    {
        return None;
    }
    let from = i.saturating_add(1);
    let mut j = from;
    while is_alnum(at(s, j)) || matches!(at(s, j), Some('-' | '_' | '.')) {
        j = j.saturating_add(1);
    }
    while j > from && matches!(at(s, j.saturating_sub(1)), Some('.' | '-' | '_')) {
        j = j.saturating_sub(1);
    }
    let domain = collect(s.get(from..j).unwrap_or_default());
    let g = graphemes(&domain);
    if !g.contains(&".") || g.first() == Some(&".") {
        return None;
    }
    let last = g.split(|x| *x == ".").rfind(|l| !l.is_empty())?;
    if last.contains(&"_") || last.len() < 2 {
        return None;
    }
    Some((local_len, j.saturating_sub(i)))
}

/// `(dest "title")` after "]": (dest, index after ")").
fn inline_link_tail(s: &[char], i: usize) -> Option<(String, usize)> {
    if at(s, i) != Some('(') {
        return None;
    }
    let mut j = i.saturating_add(1);
    let ws = |j: &mut usize| {
        while matches!(at(s, *j), Some(' ' | '\t' | '\n')) {
            *j = j.saturating_add(1);
        }
    };
    let escaped = |j: usize| {
        if at(s, j) == Some('\\') {
            at(s, j.saturating_add(1)).filter(|&n| is_ascii_punct(n))
        } else {
            None
        }
    };
    ws(&mut j);
    let mut dest = String::new();
    if at(s, j) == Some('<') {
        j = j.saturating_add(1);
        while let Some(c) = at(s, j).filter(|&c| c != '>' && c != '\n') {
            if let Some(n) = escaped(j) {
                dest.push(n);
                j = j.saturating_add(2);
                continue;
            }
            dest.push(c);
            j = j.saturating_add(1);
        }
        if at(s, j) != Some('>') {
            return None;
        }
        j = j.saturating_add(1);
    } else {
        let mut depth = 0usize;
        while let Some(c) = at(s, j).filter(|&c| !is_ws(c) && u32::from(c) >= 32) {
            if let Some(n) = escaped(j) {
                dest.push(n);
                j = j.saturating_add(2);
                continue;
            }
            if c == '(' {
                depth = depth.saturating_add(1);
            }
            if c == ')' {
                if depth == 0 {
                    break;
                }
                depth = depth.saturating_sub(1);
            }
            dest.push(c);
            j = j.saturating_add(1);
        }
        if depth != 0 {
            return None;
        }
    }
    ws(&mut j);
    let q = match at(s, j) {
        Some('"') => Some('"'),
        Some('\'') => Some('\''),
        Some('(') => Some(')'),
        _ => None,
    };
    if let Some(q) = q {
        j = j.saturating_add(1);
        while at(s, j).is_some_and(|c| c != q) {
            j = j.saturating_add(if escaped(j).is_some() { 2 } else { 1 });
        }
        at(s, j)?;
        j = j.saturating_add(1);
        ws(&mut j);
    }
    if at(s, j) != Some(')') {
        return None;
    }
    Some((dest, j.saturating_add(1)))
}

/// Backslash escapes of ASCII punctuation removed.
pub(crate) fn unescape(s: &str) -> String {
    if !s.contains('\\') {
        return s.to_owned();
    }
    let u: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    let mut i = 0usize;
    while let Some(c) = at(&u, i) {
        if c == '\\'
            && let Some(n) = at(&u, i.saturating_add(1)).filter(|&n| is_ascii_punct(n))
        {
            out.push(n);
            i = i.saturating_add(2);
        } else {
            out.push(c);
            i = i.saturating_add(1);
        }
    }
    out
}
