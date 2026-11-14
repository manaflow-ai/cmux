//! The Netscape bookmark file (bookmarks.md section 3): the HTML every
//! browser imports and exports. [`read`] is tolerant (tags in any case,
//! missing `</DT>` and `<p>`, unknown attributes and stray text are fine;
//! entries without a URL scheme are skipped); [`write`] gives the Bookmarks
//! Bar as the folder marked `PERSONAL_TOOLBAR_FOLDER="true"`, then Other
//! Bookmarks' children at the top level, and [`read`] returns the same tree.

use cmux_bookmarks_core::{
    BOOKMARKS_BAR, BookmarkImportNode, MAX_BOOKMARK_DEPTH, OTHER_BOOKMARKS, Tree, validate_url,
};

/// A parsed file: the toolbar folder's children (`None` when the file has
/// none) and every other top-level node, in file order.
#[derive(Debug, Clone, Default)]
pub struct Document {
    pub bar: Option<Vec<BookmarkImportNode>>,
    pub other: Vec<BookmarkImportNode>,
    /// The file nests folders deeper than [`MAX_BOOKMARK_DEPTH`]: the
    /// reader kept nothing below that depth (it never builds or walks a
    /// deeper tree), and an import of it is refused as too deep.
    pub too_deep: bool,
}

/// Nodes in `nodes`, their descendants included.
pub fn count(nodes: &[BookmarkImportNode]) -> usize {
    nodes.iter().map(|node| 1 + node.children.as_deref().map_or(0, count)).sum()
}

impl Document {
    /// Nodes in the file.
    pub fn count(&self) -> usize {
        self.bar.as_deref().map_or(0, count) + count(&self.other)
    }

    /// The whole file as the children of one "Imported" folder: the toolbar
    /// folder stays a subfolder named `bar_title`.
    pub fn nodes(self, bar_title: &str) -> Vec<BookmarkImportNode> {
        let Some(bar) = self.bar else { return self.other };
        let mut nodes = vec![folder(bar_title, None, bar)];
        nodes.extend(self.other);
        nodes
    }
}

pub(crate) fn folder(
    title: &str,
    created_ms: Option<u64>,
    children: Vec<BookmarkImportNode>,
) -> BookmarkImportNode {
    BookmarkImportNode {
        kind: "folder".into(),
        title: title.into(),
        url: None,
        created_ms,
        children: Some(children),
    }
}

pub(crate) fn link(title: &str, url: &str, created_ms: Option<u64>) -> BookmarkImportNode {
    BookmarkImportNode {
        kind: "url".into(),
        title: title.into(),
        url: Some(url.into()),
        created_ms,
        children: None,
    }
}

struct OpenFolder {
    title: String,
    created_ms: Option<u64>,
    toolbar: bool,
    anonymous: bool,
}

/// Reads a Netscape bookmark file.
pub fn read(html: &str) -> Document {
    let mut scanner = Scanner::new(html);
    let mut stack: Vec<Vec<BookmarkImportNode>> = vec![Vec::new()];
    let mut open: Vec<OpenFolder> = Vec::new();
    let mut queued: Option<OpenFolder> = None;
    let mut bar = None;
    let mut saw_root_list = false;
    // Lists open below the depth limit: counted, never built.
    let mut beyond = 0usize;
    let mut too_deep = false;
    while let Some(tag) = scanner.next_tag() {
        if beyond > 0 {
            match tag.name.as_str() {
                "dl" => beyond += 1,
                "/dl" => beyond -= 1,
                _ => {}
            }
            continue;
        }
        match tag.name.as_str() {
            "h3" => {
                let title = decode(&scanner.text_until("h3"));
                queued = Some(OpenFolder {
                    title,
                    created_ms: date_ms(tag.attribute("add_date")),
                    toolbar: tag
                        .attribute("personal_toolbar_folder")
                        .is_some_and(|value| value.eq_ignore_ascii_case("true")),
                    anonymous: false,
                });
            }
            "a" => {
                let title = decode(&scanner.text_until("a"));
                let Some(href) = tag.attribute("href").map(decode) else { continue };
                let href = href.trim();
                // A link the store would refuse (no scheme, unparsable, too long) is
                // skipped, so one bad entry never refuses the whole file.
                if validate_url(href).is_err() {
                    continue;
                }
                let created = date_ms(tag.attribute("add_date"));
                if let Some(level) = stack.last_mut() {
                    level.push(link(&title, href, created));
                }
            }
            "dl" => {
                if !saw_root_list && queued.is_none() {
                    // The file's outer list is the root itself.
                    saw_root_list = true;
                    continue;
                }
                saw_root_list = true;
                // `stack` holds the root's level and one per open list.
                if stack.len() > MAX_BOOKMARK_DEPTH {
                    queued = None;
                    beyond = 1;
                    too_deep = true;
                    continue;
                }
                // A list with no heading keeps its items in the parent.
                open.push(queued.take().unwrap_or(OpenFolder {
                    title: String::new(),
                    created_ms: None,
                    toolbar: false,
                    anonymous: true,
                }));
                stack.push(Vec::new());
            }
            "/dl" => {
                if stack.len() > 1
                    && let Some(folder) = open.pop()
                    && let Some(children) = stack.pop()
                {
                    close(folder, children, &mut stack, &mut bar);
                }
            }
            _ => {}
        }
    }
    // Unclosed lists at the end of a truncated file still count.
    while stack.len() > 1
        && let Some(folder) = open.pop()
        && let Some(children) = stack.pop()
    {
        close(folder, children, &mut stack, &mut bar);
    }
    if let Some(open) = queued
        && let Some(level) = stack.last_mut()
    {
        level.push(folder(&open.title, open.created_ms, Vec::new()));
    }
    Document { bar, other: stack.into_iter().next().unwrap_or_default(), too_deep }
}

fn close(
    open: OpenFolder,
    children: Vec<BookmarkImportNode>,
    stack: &mut [Vec<BookmarkImportNode>],
    bar: &mut Option<Vec<BookmarkImportNode>>,
) {
    let top_level = stack.len() == 1;
    let Some(level) = stack.last_mut() else { return };
    if open.toolbar && bar.is_none() && top_level {
        *bar = Some(children);
    } else if open.anonymous {
        level.extend(children);
    } else {
        level.push(folder(&open.title, open.created_ms, children));
    }
}

/// `ADD_DATE` in seconds (some writers store milliseconds or Chromium's
/// microseconds) as milliseconds.
fn date_ms(value: Option<&str>) -> Option<u64> {
    let seconds = value?.trim().parse::<f64>().ok().filter(|seconds| *seconds > 0.0)?;
    let ms = if seconds > 1e14 {
        seconds / 1000.0
    } else if seconds > 1e11 {
        seconds
    } else {
        seconds * 1000.0
    };
    (ms.is_finite() && ms < 9.0e15).then_some(ms as u64)
}

/// HTML character references (the named ones files use and numeric
/// forms), then trimmed.
pub fn decode(text: &str) -> String {
    if !text.contains('&') {
        return text.trim().to_string();
    }
    let mut result = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find('&') {
        let (head, tail) = rest.split_at(start);
        result.push_str(head);
        let window = tail.char_indices().take(12).find(|(_, c)| *c == ';').map(|(index, _)| index);
        let scalar = window
            .and_then(|end| tail.get(1..end))
            .and_then(|entity| entity_scalar(&entity.to_ascii_lowercase()));
        match (window, scalar) {
            (Some(end), Some(scalar)) => {
                result.push(scalar);
                rest = tail.get(end + 1..).unwrap_or("");
            }
            _ => {
                result.push('&');
                rest = tail.get(1..).unwrap_or("");
            }
        }
    }
    result.push_str(rest);
    result.trim().to_string()
}

fn entity_scalar(entity: &str) -> Option<char> {
    match entity {
        "amp" => Some('&'),
        "lt" => Some('<'),
        "gt" => Some('>'),
        "quot" => Some('"'),
        "apos" => Some('\''),
        "nbsp" => Some('\u{a0}'),
        _ => {
            let value = if let Some(hex) = entity.strip_prefix("#x") {
                u32::from_str_radix(hex, 16).ok()
            } else {
                entity.strip_prefix('#').and_then(|digits| digits.parse().ok())
            };
            value.and_then(char::from_u32)
        }
    }
}

// MARK: Writer

/// A profile's tree as a Netscape bookmark file.
pub fn write(tree: &Tree, bar_title: &str) -> String {
    let mut out = String::from(
        "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<!-- This is an automatically generated file.\n     It will be read and overwritten.\n     DO NOT EDIT! -->\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n",
    );
    out.push_str(&format!(
        "    <DT><H3 PERSONAL_TOOLBAR_FOLDER=\"true\">{}</H3>\n    <DL><p>\n",
        escape(bar_title)
    ));
    append(tree, BOOKMARKS_BAR, 2, &mut out);
    out.push_str("    </DL><p>\n");
    append(tree, OTHER_BOOKMARKS, 1, &mut out);
    out.push_str("</DL><p>\n");
    out
}

fn append(tree: &Tree, parent: &str, depth: usize, out: &mut String) {
    let indent = "    ".repeat(depth);
    for node in tree.children(parent) {
        let added = format!(" ADD_DATE=\"{}\"", node.created_ms / 1000);
        if node.kind == "folder" {
            out.push_str(&format!("{indent}<DT><H3{added}>{}</H3>\n", escape(&node.title)));
            out.push_str(&format!("{indent}<DL><p>\n"));
            if depth <= MAX_BOOKMARK_DEPTH {
                append(tree, &node.id, depth + 1, out);
            }
            out.push_str(&format!("{indent}</DL><p>\n"));
        } else if let Some(url) = &node.url {
            out.push_str(&format!(
                "{indent}<DT><A HREF=\"{}\"{added}>{}</A>\n",
                escape(url),
                escape(&node.title)
            ));
        }
    }
}

fn escape(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => result.push_str("&amp;"),
            '<' => result.push_str("&lt;"),
            '>' => result.push_str("&gt;"),
            '"' => result.push_str("&quot;"),
            '\n' | '\r' => result.push(' '),
            other => result.push(other),
        }
    }
    result
}

// MARK: Scanner

struct Tag {
    /// Lowercased; `/dl` for a closing tag.
    name: String,
    /// Names lowercased.
    attributes: Vec<(String, String)>,
}

impl Tag {
    fn attribute(&self, name: &str) -> Option<&str> {
        self.attributes.iter().find(|(key, _)| key == name).map(|(_, value)| value.as_str())
    }
}

/// A minimal tag tokenizer over chars: comments, `<!DOCTYPE>` and `<?...>`
/// are skipped.
struct Scanner {
    chars: Vec<char>,
    position: usize,
}

impl Scanner {
    fn new(text: &str) -> Self {
        Self { chars: text.chars().collect(), position: 0 }
    }

    fn at(&self, offset: usize) -> Option<char> {
        self.chars.get(self.position + offset).copied()
    }

    fn next_tag(&mut self) -> Option<Tag> {
        while let Some(current) = self.at(0) {
            if current != '<' {
                self.position += 1;
                continue;
            }
            if self.matches("<!--", false) {
                self.skip_past("-->");
                continue;
            }
            self.position += 1;
            if matches!(self.at(0), Some('!' | '?')) {
                self.skip_past(">");
                continue;
            }
            let mut name = String::new();
            if self.at(0) == Some('/') {
                name.push('/');
                self.position += 1;
            }
            while let Some(c) = self.at(0).filter(|c| is_name_char(*c)) {
                name.push(c);
                self.position += 1;
            }
            if name.is_empty() || name == "/" {
                continue;
            }
            let attributes = self.read_attributes();
            return Some(Tag { name: name.to_ascii_lowercase(), attributes });
        }
        None
    }

    /// Raw text up to the closing `</name>` (past it), or up to the next tag
    /// that opens an entry, for files that forget to close.
    fn text_until(&mut self, name: &str) -> String {
        let closing = format!("</{name}");
        let mut text = String::new();
        while let Some(c) = self.at(0) {
            if c == '<' {
                if self.matches(&closing, true) {
                    self.skip_past(">");
                    return text;
                }
                if self.matches("<dt", true)
                    || self.matches("<dl", true)
                    || self.matches("</dl", true)
                {
                    return text;
                }
            }
            text.push(c);
            self.position += 1;
        }
        text
    }

    fn read_attributes(&mut self) -> Vec<(String, String)> {
        let mut attributes = Vec::new();
        while self.at(0).is_some() {
            self.skip_whitespace();
            let Some(current) = self.at(0) else { break };
            if current == '>' {
                self.position += 1;
                break;
            }
            if current == '/' {
                self.position += 1;
                continue;
            }
            let mut name = String::new();
            while let Some(c) = self.at(0).filter(|c| is_name_char(*c) || *c == '-') {
                name.push(c);
                self.position += 1;
            }
            if name.is_empty() {
                self.position += 1;
                continue;
            }
            self.skip_whitespace();
            let mut value = String::new();
            if self.at(0) == Some('=') {
                self.position += 1;
                self.skip_whitespace();
                if let Some(quote) = self.at(0).filter(|c| *c == '"' || *c == '\'') {
                    self.position += 1;
                    while let Some(c) = self.at(0).filter(|c| *c != quote) {
                        value.push(c);
                        self.position += 1;
                    }
                    self.position += 1;
                } else {
                    while let Some(c) = self.at(0).filter(|c| !c.is_whitespace() && *c != '>') {
                        value.push(c);
                        self.position += 1;
                    }
                }
            }
            let name = name.to_ascii_lowercase();
            attributes.retain(|(key, _): &(String, String)| *key != name);
            attributes.push((name, value));
        }
        attributes
    }

    fn matches(&self, pattern: &str, case_insensitive: bool) -> bool {
        pattern.chars().enumerate().all(|(offset, expected)| {
            self.at(offset).is_some_and(|actual| {
                if case_insensitive {
                    actual.eq_ignore_ascii_case(&expected)
                } else {
                    actual == expected
                }
            })
        })
    }

    fn skip_past(&mut self, terminator: &str) {
        while self.position < self.chars.len() && !self.matches(terminator, false) {
            self.position += 1;
        }
        self.position = (self.position + terminator.chars().count()).min(self.chars.len());
    }

    fn skip_whitespace(&mut self) {
        while self.at(0).is_some_and(char::is_whitespace) {
            self.position += 1;
        }
    }
}

fn is_name_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}
