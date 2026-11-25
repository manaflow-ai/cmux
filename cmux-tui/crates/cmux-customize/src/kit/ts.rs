//! A small reader for the kit's TypeScript: enough of the language to list
//! what `kit/index.ts` exports, each component's props (their types, docs,
//! defaults and string-literal values), and the gallery entries that cover
//! it. It is not a TypeScript parser. It reads the shapes the kit is written
//! in (`export function Name({ a = 1 }: NameProps)`, `export interface
//! NameProps extends Omit<Other, "x"> { ... }`, `export type Tone = "a" |
//! "b"`, `keyof typeof TABLE`, `Props["key"]`), and a type it cannot read is
//! reported as written, never guessed. Row 1's manifest generator
//! (`webviews/scripts/gen-component-manifest.ts`) answers the same questions
//! with the TypeScript checker; this follows its status rule.

use serde_json::{Map, Value, json};

use super::sources::{GALLERIES, SOURCES, source};

/// How far a type may refer to another before the reader gives up on it.
const MAX_DEPTH: usize = 8;

/// The longest summary a component carries, in characters.
const MAX_SUMMARY: usize = 600;

const BARREL: &str = "kit/index.ts";

// ---------------------------------------------------------------------------
// Lexing: strings, comments and brackets.

fn is_ident(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'$'
}

fn find_from(b: &[u8], from: usize, pat: &[u8]) -> Option<usize> {
    b.get(from..)?.windows(pat.len()).position(|w| w == pat).map(|p| p + from)
}

/// The index after the string or comment starting at `i`, or `None` when
/// `i` starts neither.
fn skip_trivia(b: &[u8], i: usize) -> Option<usize> {
    match b[i] {
        q @ (b'"' | b'\'' | b'`') => {
            let mut j = i + 1;
            while j < b.len() {
                if b[j] == b'\\' {
                    j += 2;
                    continue;
                }
                if b[j] == q {
                    return Some(j + 1);
                }
                // A quote string ends with its line; an apostrophe in JSX
                // text (`Don't`) must not swallow the file.
                if b[j] == b'\n' && q != b'`' {
                    return Some(j);
                }
                j += 1;
            }
            Some(b.len())
        }
        b'/' if b.get(i + 1) == Some(&b'/') => {
            Some(b[i..].iter().position(|&c| c == b'\n').map_or(b.len(), |p| i + p))
        }
        b'/' if b.get(i + 1) == Some(&b'*') => {
            Some(find_from(b, i + 2, b"*/").map_or(b.len(), |p| p + 2))
        }
        _ => None,
    }
}

/// Whether the byte at `i` opens or closes a bracket: +1, -1 or 0. `<` and
/// `>` count only when `angles` (in type text), and never the `>` of `=>`.
fn bracket(b: &[u8], i: usize, angles: bool) -> i32 {
    match b[i] {
        b'{' | b'(' | b'[' => 1,
        b'}' | b')' | b']' => -1,
        b'<' if angles => 1,
        b'>' if angles && !(i > 0 && b[i - 1] == b'=') => -1,
        _ => 0,
    }
}

/// The index of the bracket closing the one at `open`.
fn closing(text: &str, open: usize, angles: bool) -> Option<usize> {
    let b = text.as_bytes();
    let mut depth = 0i32;
    let mut i = open;
    while i < b.len() {
        if let Some(next) = skip_trivia(b, i) {
            i = next;
            continue;
        }
        depth += bracket(b, i, angles);
        if depth <= 0 {
            return Some(i);
        }
        i += 1;
    }
    None
}

/// `text` split at each top-level byte in `seps`, skipping strings and comments.
fn split_top<'a>(text: &'a str, seps: &[u8], angles: bool) -> Vec<&'a str> {
    let b = text.as_bytes();
    let (mut out, mut depth, mut start, mut i) = (Vec::new(), 0i32, 0, 0);
    while i < b.len() {
        if let Some(next) = skip_trivia(b, i) {
            i = next;
            continue;
        }
        let step = bracket(b, i, angles);
        if step != 0 {
            depth += step;
        } else if depth == 0 && seps.contains(&b[i]) {
            out.push(&text[start..i]);
            start = i + 1;
        }
        i += 1;
    }
    out.push(&text[start..]);
    out
}

/// The text from `from` up to the first top-level `;` (or the end).
fn until_semicolon(text: &str, from: usize) -> &str {
    let rest = &text[from..];
    let b = rest.as_bytes();
    let (mut depth, mut i) = (0i32, 0);
    while i < b.len() {
        if let Some(next) = skip_trivia(b, i) {
            i = next;
            continue;
        }
        depth += bracket(b, i, true);
        if depth < 0 || (depth == 0 && b[i] == b';') {
            return &rest[..i];
        }
        i += 1;
    }
    rest
}

/// A string literal's text, when `text` is exactly one.
fn string_lit(text: &str) -> Option<String> {
    let text = text.trim();
    let q = *text.as_bytes().first()?;
    if !matches!(q, b'"' | b'\'' | b'`') || text.len() < 2 || !text.ends_with(q as char) {
        return None;
    }
    let inner = &text[1..text.len() - 1];
    if (inner.contains(q as char) && !inner.contains('\\')) || (q == b'`' && inner.contains("${")) {
        return None;
    }
    Some(inner.replace(&format!("\\{}", q as char), &(q as char).to_string()))
}

/// One line of whitespace for a run of it.
fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The leading identifier of `text` (or its leading quoted key) and the rest.
fn leading_name(text: &str) -> Option<(String, &str)> {
    let b = text.as_bytes();
    if let Some(&q) = b.first()
        && matches!(q, b'"' | b'\'')
    {
        let end = skip_trivia(b, 0)?;
        return Some((string_lit(&text[..end])?, &text[end..]));
    }
    let end = b.iter().position(|&c| !is_ident(c)).unwrap_or(b.len());
    (end > 0).then(|| (text[..end].to_owned(), &text[end..]))
}

// ---------------------------------------------------------------------------
// Comments as docs.

fn clean_block(comment: &str) -> String {
    let inner = comment.trim().trim_start_matches("/**").trim_start_matches("/*");
    let inner = inner.strip_suffix("*/").unwrap_or(inner);
    one_line(
        &inner
            .lines()
            .map(|l| l.trim().trim_start_matches('*').trim())
            .collect::<Vec<_>>()
            .join(" "),
    )
}

/// The `/** */` or `///` comments that open `piece`, and what follows them.
fn leading_doc(piece: &str) -> (Option<String>, &str) {
    let mut rest = piece.trim_start();
    let mut docs = Vec::new();
    loop {
        if rest.starts_with("/*") {
            let end = rest.find("*/").map_or(rest.len(), |p| p + 2);
            if rest.starts_with("/**") {
                docs.push(clean_block(&rest[..end]));
            }
            rest = rest[end..].trim_start();
        } else if rest.starts_with("//") {
            let end = rest.find('\n').unwrap_or(rest.len());
            if let Some(line) = rest[..end].strip_prefix("///") {
                docs.push(line.trim().to_owned());
            }
            rest = rest[end..].trim_start();
        } else {
            break;
        }
    }
    let doc = one_line(&docs.join(" "));
    ((!doc.is_empty()).then_some(doc), rest)
}

/// The doc comment right above the line starting at `line_start`.
fn doc_before(text: &str, line_start: usize) -> Option<String> {
    let before = text[..line_start].trim_end();
    if before.ends_with("*/") {
        let open = before.rfind("/**")?;
        return Some(clean_block(&before[open..]));
    }
    let mut lines = Vec::new();
    for line in before.lines().rev() {
        match line.trim().strip_prefix("///") {
            Some(doc) => lines.push(doc.trim()),
            None => break,
        }
    }
    lines.reverse();
    let doc = one_line(&lines.join(" "));
    (!doc.is_empty()).then_some(doc)
}

/// The `//` comment a file opens with, past a JSX pragma and the closed-file note.
fn file_summary(text: &str) -> String {
    let mut lines = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with("/** @jsx") {
            continue;
        }
        match line.strip_prefix("//") {
            Some(comment) => {
                let comment = comment.trim_start_matches('/').trim();
                if !comment.starts_with("A closed file") {
                    lines.push(comment);
                }
            }
            None => break,
        }
    }
    one_line(&lines.join(" "))
}

fn capped(text: String) -> String {
    if text.chars().count() <= MAX_SUMMARY {
        return text;
    }
    let mut out: String = text.chars().take(MAX_SUMMARY).collect();
    if let Some(stop) = out.rfind(". ") {
        out.truncate(stop + 1);
    } else {
        out.push_str("...");
    }
    out
}

// ---------------------------------------------------------------------------
// Modules: imports, exports and declarations.

/// One `export { ... } from "spec"` or `import { ... } from "spec"`.
struct BraceStatement {
    /// The names it lists: (exported name, local name, type-only), where the
    /// local name differs for `Local as Exported`.
    names: Vec<(String, String, bool)>,
    spec: String,
}

fn brace_statements(text: &str, keyword: &str) -> Vec<BraceStatement> {
    let mut out = Vec::new();
    let mut offset = 0;
    for line in text.split_inclusive('\n') {
        let at = offset;
        offset += line.len();
        let Some(rest) = line.strip_prefix(keyword).and_then(|r| r.strip_prefix(' ')) else {
            continue;
        };
        let (all_types, rest) = match rest.strip_prefix("type ") {
            Some(r) => (true, r),
            None => (false, rest),
        };
        if !rest.starts_with('{') {
            continue;
        }
        let open = at + line.len() - rest.len();
        let Some(close) = closing(text, open, false) else { continue };
        let after = text[close + 1..].trim_start();
        let Some(after) = after.strip_prefix("from") else { continue };
        let after = after.trim_start();
        if !after.starts_with(['"', '\'']) {
            continue;
        }
        let Some(end) = skip_trivia(after.as_bytes(), 0) else { continue };
        let Some(spec) = string_lit(&after[..end]) else { continue };
        let names = split_top(&text[open + 1..close], b",", false)
            .into_iter()
            .filter_map(|item| {
                let item = leading_doc(item).1.trim();
                let (is_type, item) = match item.strip_prefix("type ") {
                    Some(i) => (true, i.trim()),
                    None => (all_types, item),
                };
                let local = item.split(" as ").next()?.trim();
                let name = item.rsplit(" as ").next()?.trim();
                (!name.is_empty()).then(|| (name.to_owned(), local.to_owned(), is_type))
            })
            .collect();
        out.push(BraceStatement { names, spec });
    }
    out
}

/// The `export * from "spec"` statements of a file.
fn star_exports(text: &str) -> Vec<String> {
    text.lines()
        .filter_map(|l| l.trim().strip_prefix("export * from "))
        .filter_map(|s| string_lit(s.trim_end_matches(';')))
        .collect()
}

/// The file a relative module specifier names, among the compiled-in sources.
fn resolve(from: &str, spec: &str) -> Option<&'static str> {
    if !spec.starts_with('.') {
        return None;
    }
    let mut parts: Vec<&str> = from.split('/').collect();
    parts.pop();
    for seg in spec.split('/') {
        match seg {
            "." | "" => {}
            ".." => {
                parts.pop();
            }
            s => parts.push(s),
        }
    }
    let base = parts.join("/");
    ["", ".tsx", ".ts", "/index.ts", "/index.tsx"].iter().find_map(|ext| {
        let path = format!("{base}{ext}");
        SOURCES.iter().find(|(p, _)| *p == path).map(|(p, _)| *p)
    })
}

/// Where `keyword name` is declared at the start of a line of `text`
/// (after `export`, `declare` or `default`): the line's start and the index
/// just past the name.
fn decl_at(text: &str, keyword: &str, name: &str) -> Option<(usize, usize)> {
    let mut start = 0;
    for line in text.split_inclusive('\n') {
        let mut rest = line;
        for prefix in ["export ", "declare ", "default "] {
            rest = rest.strip_prefix(prefix).unwrap_or(rest);
        }
        if let Some(after) = rest
            .strip_prefix(keyword)
            .and_then(|r| r.strip_prefix(' '))
            .and_then(|r| r.strip_prefix(name))
            && !after.as_bytes().first().is_some_and(|&c| is_ident(c))
        {
            return Some((start, start + line.len() - after.len()));
        }
        start += line.len();
    }
    None
}

/// Skips a generic parameter list (`<T>`) at the start of `text[at..]`.
fn past_generics(text: &str, at: usize) -> usize {
    let trimmed = text[at..].trim_start();
    let at = text.len() - trimmed.len();
    if trimmed.starts_with('<') { closing(text, at, true).map_or(at, |c| c + 1) } else { at }
}

/// The files to look in for a name `file` uses: the file, then the one it
/// imports the name from, then every other source.
fn lookup_order(name: &str, file: &'static str) -> Vec<&'static str> {
    let mut order = vec![file];
    if let Some(text) = source(file) {
        for statement in
            brace_statements(text, "import").into_iter().chain(brace_statements(text, "export"))
        {
            if statement.names.iter().any(|(n, _, _)| n == name)
                && let Some(target) = resolve(file, &statement.spec)
                && !order.contains(&target)
            {
                order.push(target);
            }
        }
    }
    for &(path, _) in SOURCES {
        if !order.contains(&path) {
            order.push(path);
        }
    }
    order
}

enum TypeDef {
    Interface { extends: Vec<String>, body: String },
    Alias(String),
}

fn find_type(name: &str, file: &'static str) -> Option<(&'static str, TypeDef)> {
    for path in lookup_order(name, file) {
        let text = source(path)?;
        if let Some((_, after)) = decl_at(text, "interface", name) {
            let at = past_generics(text, after);
            let open = at + text[at..].find('{')?;
            let close = closing(text, open, false)?;
            let head = text[at..open].trim();
            let extends = head
                .strip_prefix("extends")
                .map(|e| {
                    split_top(e, b",", true)
                        .into_iter()
                        .map(one_line)
                        .filter(|t| !t.is_empty())
                        .collect()
                })
                .unwrap_or_default();
            return Some((
                path,
                TypeDef::Interface { extends, body: text[open + 1..close].to_owned() },
            ));
        }
        if let Some((_, after)) = decl_at(text, "type", name) {
            let at = past_generics(text, after);
            let rest = text[at..].trim_start();
            let Some(value) = rest.strip_prefix('=') else { continue };
            let from = text.len() - value.len();
            return Some((path, TypeDef::Alias(until_semicolon(text, from).trim().to_owned())));
        }
    }
    None
}

/// The top-level keys of a `const NAME = { ... }` object.
fn const_keys(name: &str, file: &'static str) -> Vec<String> {
    for path in lookup_order(name, file) {
        let Some(text) = source(path) else { continue };
        let Some((_, after)) = decl_at(text, "const", name) else { continue };
        let Some(eq) = text[after..].find('=').map(|p| p + after) else { continue };
        let Some(open) = text[eq..].find('{').map(|p| p + eq) else { continue };
        if !text[eq + 1..open].trim().is_empty() {
            continue;
        }
        let Some(close) = closing(text, open, false) else { continue };
        return object_entries(&text[open + 1..close]).into_iter().map(|(k, _)| k).collect();
    }
    Vec::new()
}

/// An object literal's top-level `key: value` entries (a shorthand `key`
/// gives itself as the value).
fn object_entries(body: &str) -> Vec<(String, &str)> {
    split_top(body, b",", false)
        .into_iter()
        .filter_map(|piece| {
            let rest = leading_doc(piece).1.trim();
            let rest = rest.strip_prefix("...").map_or(rest, |_| "");
            let (key, after) = leading_name(rest)?;
            let after = after.trim_start();
            let value = after.strip_prefix(':').map_or(after, str::trim);
            Some((key, if value.is_empty() { rest } else { value }))
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Props.

#[derive(Clone, Debug)]
pub(super) struct Prop {
    pub(super) name: String,
    pub(super) ty: String,
    pub(super) optional: bool,
    pub(super) doc: Option<String>,
    pub(super) default: Option<String>,
    /// The string values the type allows, when it is a union of them.
    pub(super) values: Vec<String>,
    /// The file the type text is written in, to resolve the names it uses.
    at: &'static str,
}

#[derive(Default)]
struct Props {
    props: Vec<Prop>,
    /// What the props extend that is not the kit's own (`ComponentProps<typeof BaseButton>`).
    extends: Vec<String>,
}

impl Props {
    /// Adds `other`'s props under these: a name already here wins.
    fn under(&mut self, other: Props) {
        for prop in other.props {
            if !self.props.iter().any(|p| p.name == prop.name) {
                self.props.push(prop);
            }
        }
        for e in other.extends {
            if !self.extends.contains(&e) {
                self.extends.push(e);
            }
        }
    }
}

fn parse_member(piece: &str, at: &'static str) -> Option<Prop> {
    let (doc, rest) = leading_doc(piece);
    let rest = rest.trim();
    let rest = rest.strip_prefix("readonly ").unwrap_or(rest);
    if rest.starts_with('[') {
        return None;
    }
    let (name, after) = leading_name(rest)?;
    let after = after.trim_start();
    let (optional, after) = match after.strip_prefix('?') {
        Some(a) => (true, a.trim_start()),
        None => (false, after),
    };
    let ty = if after.starts_with('(') {
        let close = closing(after, 0, false)?;
        let ret = after[close + 1..].trim_start().strip_prefix(':').map_or("void", str::trim);
        format!("{} => {ret}", &after[..=close])
    } else {
        after.strip_prefix(':')?.trim().to_owned()
    };
    let ty = one_line(ty.trim_start_matches('|').trim());
    Some(Prop { name, ty, optional, doc, default: None, values: Vec::new(), at })
}

fn members(body: &str, at: &'static str) -> Vec<Prop> {
    split_top(body, b";,", true).into_iter().filter_map(|piece| parse_member(piece, at)).collect()
}

/// The props a type names, as far as the reader can follow it.
fn type_props(ty: &str, file: &'static str, depth: usize) -> Props {
    let ty = ty.trim();
    let mut out = Props::default();
    if depth > MAX_DEPTH || ty.is_empty() {
        out.extends.push(one_line(ty));
        return out;
    }
    let parts = split_top(ty, b"&", true);
    if parts.len() > 1 {
        for part in parts {
            out.under(type_props(part, file, depth + 1));
        }
        return out;
    }
    if ty.starts_with('{') {
        if let Some(close) = closing(ty, 0, false) {
            out.props = members(&ty[1..close], file);
        }
        return out;
    }
    if let Some(inner) = ty.strip_prefix("Omit<").and_then(|i| i.strip_suffix('>')) {
        let args = split_top(inner, b",", true);
        let mut base = type_props(args[0], file, depth + 1);
        let dropped = args.get(1).map(|keys| values(keys, file, depth + 1)).unwrap_or_default();
        base.props.retain(|p| !dropped.contains(&p.name));
        out.under(base);
        return out;
    }
    if ty.bytes().all(is_ident) {
        match find_type(ty, file) {
            Some((at, TypeDef::Interface { extends, body })) => {
                out.props = members(&body, at);
                for e in extends {
                    out.under(type_props(&e, at, depth + 1));
                }
            }
            Some((at, TypeDef::Alias(value))) => out.under(type_props(&value, at, depth + 1)),
            None => out.extends.push(ty.to_owned()),
        }
        return out;
    }
    out.extends.push(one_line(ty));
    out
}

/// The string values a type allows, when it is a union of string literals
/// (through aliases, `keyof typeof TABLE` and `Props["key"]`); empty otherwise.
fn values(ty: &str, file: &'static str, depth: usize) -> Vec<String> {
    if depth > MAX_DEPTH {
        return Vec::new();
    }
    let mut out = Vec::new();
    for part in split_top(ty.trim(), b"|", true) {
        let part = part.trim();
        if part.is_empty() || part == "undefined" || part == "null" {
            continue;
        }
        let found = if let Some(lit) = string_lit(part) {
            vec![lit]
        } else if let Some(table) = part.strip_prefix("keyof typeof ") {
            const_keys(table.trim(), file)
        } else if part.ends_with(']')
            && let Some(open) = part.find('[')
            && let Some(key) = string_lit(&part[open + 1..part.len() - 1])
        {
            let base = type_props(&part[..open], file, depth + 1);
            base.props
                .iter()
                .find(|p| p.name == key)
                .map(|p| values(&p.ty, p.at, depth + 1))
                .unwrap_or_default()
        } else if part.bytes().all(is_ident) {
            match find_type(part, file) {
                Some((at, TypeDef::Alias(value))) => values(&value, at, depth + 1),
                _ => Vec::new(),
            }
        } else {
            Vec::new()
        };
        if found.is_empty() {
            return Vec::new();
        }
        for v in found {
            if !out.contains(&v) {
                out.push(v);
            }
        }
    }
    out
}

/// The parameter list of a component declared at `after` (just past its
/// name): the destructured defaults and the props type.
fn signature(text: &str, after: usize) -> (Vec<(String, String)>, Option<String>) {
    let mut at = past_generics(text, after);
    let rest = text[at..].trim_start();
    at = text.len() - rest.len();
    if !rest.starts_with('(') {
        // `const Name = (` or `const Name: T = (`.
        let Some(eq) = rest.find('=') else { return (Vec::new(), None) };
        let tail = rest[eq + 1..].trim_start();
        at = text.len() - tail.len();
    }
    if !text[at..].starts_with('(') {
        return (Vec::new(), None);
    }
    let Some(close) = closing(text, at, false) else { return (Vec::new(), None) };
    let params = &text[at + 1..close];
    let first = split_top(params, b",", true).into_iter().next().unwrap_or("").trim();
    if first.is_empty() {
        return (Vec::new(), None);
    }
    let (defaults, ty) = if first.starts_with('{') {
        let Some(end) = closing(first, 0, false) else { return (Vec::new(), None) };
        let defaults = split_top(&first[1..end], b",", true)
            .into_iter()
            .filter_map(|piece| {
                let piece = piece.trim();
                let (name, _) = leading_name(piece)?;
                let (_, value) = piece.split_once(" = ")?;
                Some((name, one_line(value)))
            })
            .collect();
        (defaults, first[end + 1..].trim_start().strip_prefix(':').map(str::trim))
    } else {
        (Vec::new(), first.split_once(':').map(|(_, t)| t.trim()))
    };
    let ty = ty.map(|t| t.strip_suffix("= {}").unwrap_or(t).trim().to_owned());
    (defaults, ty)
}

// ---------------------------------------------------------------------------
// Gallery entries.

#[derive(Clone, Debug)]
pub(super) struct Entry {
    pub(super) id: String,
    pub(super) title: String,
    pub(super) file: &'static str,
    pub(super) experimental: bool,
    /// The variant names, or `None` when the entry computes them.
    pub(super) variants: Option<Vec<String>>,
    pub(super) covers: Vec<String>,
}

pub(super) fn gallery_entries() -> Vec<Entry> {
    let mut out = Vec::new();
    for &(file, text) in GALLERIES {
        let b = text.as_bytes();
        let mut from = 0;
        while let Some(at) = find_from(b, from, b"componentEntry") {
            from = at + "componentEntry".len();
            let open = past_generics(text, from);
            if !text[open..].starts_with('(') {
                continue;
            }
            let rest = text[open + 1..].trim_start();
            if !rest.starts_with('{') {
                continue;
            }
            let brace = text.len() - rest.len();
            let Some(close) = closing(text, brace, false) else { continue };
            let entries = object_entries(&text[brace + 1..close]);
            let field = |key: &str| entries.iter().find(|(k, _)| k == key).map(|(_, v)| *v);
            let text_of = |key: &str| {
                field(key).map(|v| string_lit(v).unwrap_or_else(|| one_line(v))).unwrap_or_default()
            };
            let variants = field("variants").and_then(|v| {
                let v = v.trim();
                if !v.starts_with('{') {
                    return None;
                }
                let end = closing(v, 0, false)?;
                Some(object_entries(&v[1..end]).into_iter().map(|(k, _)| k).collect())
            });
            let covers = field("covers")
                .and_then(|v| {
                    let v = v.trim();
                    let end = closing(v, 0, false).filter(|_| v.starts_with('['))?;
                    Some(
                        split_top(&v[1..end], b",", false)
                            .into_iter()
                            .filter_map(string_lit)
                            .collect(),
                    )
                })
                .unwrap_or_default();
            out.push(Entry {
                id: text_of("id"),
                title: text_of("title"),
                file,
                experimental: field("experimental").is_some_and(|v| v.trim() == "true"),
                variants,
                covers,
            });
            from = close;
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Components.

#[derive(Debug)]
pub(super) struct Component {
    pub(super) name: String,
    /// The file it is declared in, under `webviews/src`.
    pub(super) file: &'static str,
    pub(super) status: String,
    pub(super) summary: String,
    pub(super) props: Vec<Prop>,
    pub(super) extends: Vec<String>,
    pub(super) galleries: Vec<Entry>,
    /// The name it is declared as, when the barrel exports it under another
    /// (`AnchoredCard as Card`).
    pub(super) alias_of: Option<String>,
}

/// A value export of the barrel that names a component: capitalized and
/// not a CONSTANT.
fn is_component_name(name: &str) -> bool {
    name.starts_with(|c: char| c.is_ascii_uppercase())
        && name.bytes().any(|c| c.is_ascii_lowercase())
}

/// The kit barrel's re-export targets that are not compiled in.
pub(super) fn barrel_misses() -> Vec<String> {
    let text = source(BARREL).unwrap_or_default();
    brace_statements(text, "export")
        .into_iter()
        .map(|s| s.spec)
        .chain(star_exports(text))
        .filter(|spec| resolve(BARREL, spec).is_none())
        .collect()
}

pub(super) fn kit_components() -> Vec<Component> {
    let text = source(BARREL).unwrap_or_default();
    let entries = gallery_entries();
    let mut out = Vec::new();
    for statement in brace_statements(text, "export") {
        let Some(file) = resolve(BARREL, &statement.spec) else { continue };
        for (name, local, is_type) in &statement.names {
            if !is_type && is_component_name(name) {
                let mut found = component(local, file, vec![file], &entries, 0);
                if name != local {
                    found.alias_of = Some(found.name.clone());
                    found.name = name.clone();
                }
                out.push(found);
            }
        }
    }
    out
}

fn component(
    name: &str,
    file: &'static str,
    mut via: Vec<&'static str>,
    entries: &[Entry],
    depth: usize,
) -> Component {
    let text = source(file).unwrap_or_default();
    let decl = decl_at(text, "function", name).or_else(|| decl_at(text, "const", name));
    let Some((line, after)) = decl else {
        // Re-exported from another file (`export { Spinner } from "./Spinner"`).
        for statement in brace_statements(text, "export") {
            if depth < MAX_DEPTH
                && statement.names.iter().any(|(n, _, t)| n == name && !t)
                && let Some(target) = resolve(file, &statement.spec)
            {
                via.push(target);
                return component(name, target, via, entries, depth + 1);
            }
        }
        return Component {
            name: name.to_owned(),
            file,
            status: "ready".into(),
            summary: format!("No declaration of {name} found in {file}."),
            props: Vec::new(),
            extends: Vec::new(),
            galleries: Vec::new(),
            alias_of: None,
        };
    };
    let doc = doc_before(text, line);
    let (defaults, ty) = signature(text, after);
    let Props { mut props, extends } = ty.map(|t| type_props(&t, file, 0)).unwrap_or_default();
    for prop in &mut props {
        prop.default = defaults.iter().find(|(n, _)| *n == prop.name).map(|(_, v)| v.clone());
        prop.values = values(&prop.ty, prop.at, 0);
    }
    let galleries: Vec<Entry> = entries
        .iter()
        .filter(|e| via.iter().any(|f| e.covers.iter().any(|c| *c == format!("{f}#{name}"))))
        .cloned()
        .collect();
    let explicit = doc
        .as_deref()
        .and_then(|d| d.split("@status ").nth(1))
        .and_then(|s| s.split_whitespace().next())
        .map(str::to_owned);
    let status = explicit.unwrap_or_else(|| {
        if !galleries.is_empty() && galleries.iter().all(|e| e.experimental) {
            "experimental"
        } else {
            "ready"
        }
        .into()
    });
    let summary = capped(doc.filter(|d| !d.is_empty()).unwrap_or_else(|| file_summary(text)));
    Component {
        name: name.to_owned(),
        file,
        status,
        summary,
        props,
        extends,
        galleries,
        alias_of: None,
    }
}

impl Component {
    pub(super) fn to_json(&self) -> Value {
        let props: Vec<Value> = self
            .props
            .iter()
            .map(|p| {
                let mut o = Map::new();
                o.insert("name".into(), json!(p.name));
                o.insert("type".into(), json!(p.ty));
                o.insert("optional".into(), json!(p.optional));
                if let Some(d) = &p.default {
                    o.insert("default".into(), json!(d));
                }
                if !p.values.is_empty() {
                    o.insert("values".into(), json!(p.values));
                }
                if let Some(d) = &p.doc {
                    o.insert("doc".into(), json!(d));
                }
                Value::Object(o)
            })
            .collect();
        let variants: Map<String, Value> = self
            .props
            .iter()
            .filter(|p| !p.values.is_empty())
            .map(|p| (p.name.clone(), json!(p.values)))
            .collect();
        let galleries: Vec<Value> = self
            .galleries
            .iter()
            .map(|e| {
                json!({
                    "id": e.id,
                    "title": e.title,
                    "file": format!("webviews/src/{}", e.file),
                    "experimental": e.experimental,
                    "variants": e.variants.clone().map_or_else(|| json!("computed in the entry"), |v| json!(v)),
                })
            })
            .collect();
        let mut out = Map::new();
        out.insert("name".into(), json!(self.name));
        if let Some(local) = &self.alias_of {
            out.insert("aliasOf".into(), json!(local));
        }
        out.insert("file".into(), json!(format!("webviews/src/{}", self.file)));
        out.insert("status".into(), json!(self.status));
        out.insert("summary".into(), json!(self.summary));
        out.insert("props".into(), json!(props));
        if !self.extends.is_empty() {
            out.insert("extends".into(), json!(self.extends));
        }
        out.insert("variants".into(), Value::Object(variants));
        out.insert("galleryEntries".into(), json!(galleries));
        out.insert("example".into(), json!(self.example()));
        Value::Object(out)
    }

    /// One JSX use: every required prop, the first variant prop set off its
    /// default, and children when it takes them.
    pub(super) fn example(&self) -> String {
        let mut attrs = Vec::new();
        for p in self.props.iter().filter(|p| !p.optional && p.name != "children") {
            attrs.push(attribute(&self.name, p, None));
        }
        if let Some(p) = self.props.iter().find(|p| p.optional && !p.values.is_empty()) {
            let default = p.default.as_deref().and_then(string_lit);
            if let Some(pick) = p.values.iter().find(|v| Some(*v) != default.as_ref()) {
                attrs.push(attribute(&self.name, p, Some(pick)));
            }
        }
        let open = if attrs.is_empty() {
            self.name.clone()
        } else {
            format!("{} {}", self.name, attrs.join(" "))
        };
        if self.props.iter().any(|p| p.name == "children") {
            format!("<{open}>...</{}>", self.name)
        } else {
            format!("<{open} />")
        }
    }
}

fn capitalized(name: &str) -> String {
    let mut chars = name.chars();
    chars.next().map(|c| c.to_ascii_uppercase().to_string() + chars.as_str()).unwrap_or_default()
}

/// One `name=value` for an example, from the prop's values or its type.
fn attribute(component: &str, p: &Prop, pick: Option<&String>) -> String {
    if let Some(v) = pick.or(p.values.first()) {
        return format!("{}=\"{v}\"", p.name);
    }
    let ty = p.ty.as_str();
    let value = match (component, p.name.as_str()) {
        ("Icon", "name") => "\"action.copy\"".to_owned(),
        _ if ty == "boolean" => return p.name.clone(),
        _ if ty == "string" || ty.contains("ReactNode") => format!("\"{}\"", capitalized(&p.name)),
        _ if ty == "number" => "{16}".to_owned(),
        _ if ty.contains("=>") => {
            let args = ty.split_once(')').map(|(a, _)| a.trim_start_matches('(')).unwrap_or("");
            let names: Vec<&str> = split_top(args, b",", true)
                .into_iter()
                .filter_map(|a| a.split(':').next().map(str::trim))
                .filter(|a| !a.is_empty())
                .collect();
            let body = if ty.ends_with("=> string") {
                names.first().map_or("\"\"".to_owned(), |n| n.to_string())
            } else {
                "{}".to_owned()
            };
            format!("{{({}) => {body}}}", names.join(", "))
        }
        _ => format!("{{{}}}", p.name),
    };
    format!("{}={value}", p.name)
}
