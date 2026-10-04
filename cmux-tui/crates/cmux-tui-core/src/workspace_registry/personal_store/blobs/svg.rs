//! The SVG sanitizer of the blob store. The input is parsed with a real XML
//! parser and only an allowlisted tree is kept and re-serialized: the input
//! bytes are never passed through.
//!
//! Kept: the elements in `ELEMENTS` in the SVG namespace, the attributes in
//! `ATTRIBUTES` (no namespace) and `xlink:href`, and text inside `title` and
//! `desc`. An `href` must start with `#`. In every kept attribute value each
//! function must be in `FUNCTIONS`, every `url()` must name `#id`, and no
//! `:` (no scheme of any kind) or `\` (no CSS escape) may appear.
//!
//! Dropped: every other element with its whole subtree (`script`, `style`,
//! `foreignObject`, `image`, `a`, animation, text, ...), every other
//! attribute (`style`, `on*`, ...), comments, processing instructions, the
//! XML declaration, CDATA sections and the DOCTYPE. An entity the DOCTYPE
//! declares is never expanded: a reference to any entity other than the five
//! predefined ones refuses the document.
//!
//! A `use` that names an element holding a `use` (itself or an ancestor
//! included) is dropped, so references cannot multiply or cycle.
//!
//! Refused: input over 64 KiB, input that is not UTF-8 or not well-formed
//! XML, a root that is not `svg` in the SVG namespace, nesting deeper than
//! `MAX_DEPTH`, and output over 64 KiB.
//!
//! The page-side copy of this allowlist is webviews/src/icon-picker/
//! svgSanitize.ts (it compares names in lowercase); keep the two equal.

use std::collections::HashSet;

use quick_xml::NsReader;
use quick_xml::XmlVersion;
use quick_xml::escape::{escape, resolve_predefined_entity};
use quick_xml::events::{BytesStart, Event};
use quick_xml::name::{Namespace, ResolveResult};

use super::{MAX_SVG_BYTES, invalid_asset};

pub const SVG_NAMESPACE: &str = "http://www.w3.org/2000/svg";
pub const XLINK_NAMESPACE: &str = "http://www.w3.org/1999/xlink";
/// Deepest accepted element nesting.
pub const MAX_DEPTH: usize = 64;

pub const ELEMENTS: &[&str] = &[
    "svg",
    "g",
    "path",
    "circle",
    "ellipse",
    "line",
    "polyline",
    "polygon",
    "rect",
    "defs",
    "linearGradient",
    "radialGradient",
    "stop",
    "clipPath",
    "mask",
    "symbol",
    "use",
    "title",
    "desc",
];

/// Attributes without a namespace. `xmlns` and `xmlns:xlink` are written by
/// the serializer, never copied; `xlink:href` is matched by namespace.
pub const ATTRIBUTES: &[&str] = &[
    "viewBox",
    "width",
    "height",
    "x",
    "y",
    "x1",
    "x2",
    "y1",
    "y2",
    "cx",
    "cy",
    "r",
    "rx",
    "ry",
    "fx",
    "fy",
    "d",
    "points",
    "transform",
    "fill",
    "fill-opacity",
    "fill-rule",
    "clip-rule",
    "stroke",
    "stroke-width",
    "stroke-opacity",
    "stroke-linecap",
    "stroke-linejoin",
    "stroke-miterlimit",
    "stroke-dasharray",
    "stroke-dashoffset",
    "opacity",
    "offset",
    "stop-color",
    "stop-opacity",
    "gradientUnits",
    "gradientTransform",
    "spreadMethod",
    "clipPathUnits",
    "maskUnits",
    "maskContentUnits",
    "clip-path",
    "mask",
    "id",
    "href",
    "preserveAspectRatio",
    "version",
];

/// Functions an attribute value may call: internal references, transforms
/// and colors.
pub const FUNCTIONS: &[&str] = &[
    "url",
    "matrix",
    "translate",
    "scale",
    "rotate",
    "skewX",
    "skewY",
    "rgb",
    "rgba",
    "hsl",
    "hsla",
];

const TEXT_ELEMENTS: &[&str] = &["title", "desc"];

enum Child {
    Element(Node),
    Text(String),
}

struct Node {
    name: &'static str,
    attributes: Vec<(&'static str, String)>,
    children: Vec<Child>,
}

impl Node {
    fn push_text(&mut self, text: &str) {
        if let Some(Child::Text(last)) = self.children.last_mut() {
            last.push_str(text);
        } else if !text.is_empty() {
            self.children.push(Child::Text(text.to_string()));
        }
    }
}

fn not_svg(reason: impl std::fmt::Display) -> anyhow::Error {
    invalid_asset(format!("not an accepted SVG: {reason}"))
}

/// The sanitized SVG document, or why it was refused.
pub fn sanitize_svg(input: &[u8]) -> anyhow::Result<String> {
    if input.len() > MAX_SVG_BYTES {
        return Err(invalid_asset(format!("image/svg+xml data exceeds {MAX_SVG_BYTES} bytes")));
    }
    let text = std::str::from_utf8(input).map_err(|_| not_svg("the data is not UTF-8"))?;
    let mut reader = NsReader::from_str(text);
    let mut stack: Vec<Node> = Vec::new();
    let mut root: Option<Node> = None;
    // Depth inside a dropped element; everything there is ignored.
    let mut skipping = 0_usize;
    loop {
        let (namespace, event) =
            reader.read_resolved_event().map_err(|error| not_svg(format!("{error}")))?;
        let element_namespace = match &namespace {
            ResolveResult::Bound(Namespace(bytes)) => Some(bytes.to_vec()),
            _ => None,
        };
        match event {
            Event::Start(_) if skipping > 0 => skipping += 1,
            Event::Empty(_) if skipping > 0 => {}
            Event::Start(start) => {
                let depth = stack.len();
                open_element(
                    &reader,
                    element_namespace.as_deref(),
                    &start,
                    false,
                    &mut stack,
                    &root,
                )?;
                if stack.len() == depth {
                    skipping = 1;
                }
            }
            Event::Empty(start) => {
                if let Some(node) = open_element(
                    &reader,
                    element_namespace.as_deref(),
                    &start,
                    true,
                    &mut stack,
                    &root,
                )? {
                    match stack.last_mut() {
                        Some(parent) => parent.children.push(Child::Element(node)),
                        None => root = Some(node),
                    }
                }
            }
            Event::End(_) if skipping > 0 => skipping -= 1,
            Event::End(_) => {
                let node = stack.pop().ok_or_else(|| not_svg("an unmatched end tag"))?;
                match stack.last_mut() {
                    Some(parent) => parent.children.push(Child::Element(node)),
                    None => root = Some(node),
                }
            }
            Event::Text(text_event) => {
                let content =
                    text_event.xml10_content().map_err(|error| not_svg(format!("{error}")))?;
                push_kept_text(&mut stack, skipping, &content);
            }
            Event::GeneralRef(reference) => {
                let resolved = if reference.is_char_ref() {
                    reference
                        .resolve_char_ref()
                        .map_err(|error| not_svg(format!("{error}")))?
                        .map(String::from)
                } else {
                    let name = reference.decode().map_err(|error| not_svg(format!("{error}")))?;
                    resolve_predefined_entity(&name).map(str::to_string)
                };
                let resolved =
                    resolved.ok_or_else(|| not_svg("a reference to an undeclared entity"))?;
                push_kept_text(&mut stack, skipping, &resolved);
            }
            // Comments, processing instructions, the declaration, CDATA and
            // the DOCTYPE are dropped. The DOCTYPE's entities are never read.
            Event::Comment(_)
            | Event::PI(_)
            | Event::Decl(_)
            | Event::CData(_)
            | Event::DocType(_) => {}
            Event::Eof => break,
        }
    }
    let root = match (root, stack.is_empty(), skipping) {
        (Some(root), true, 0) => root,
        (None, _, _) => return Err(not_svg("no svg root element")),
        _ => return Err(not_svg("an unclosed element")),
    };
    let mut root = root;
    let mut nested = HashSet::new();
    ids_containing_use(&root, &mut nested);
    drop_nested_uses(&mut root, &nested);
    let mut output = String::new();
    write_node(&root, true, uses_xlink(&root), &mut output);
    if output.len() > MAX_SVG_BYTES {
        return Err(invalid_asset(format!("sanitized SVG exceeds {MAX_SVG_BYTES} bytes")));
    }
    Ok(output)
}

/// Check one start or empty tag. A kept start tag is pushed on `stack`; a
/// kept empty tag is returned for the caller to attach. A start tag that
/// leaves `stack` unchanged was not kept: the caller skips its subtree.
fn open_element(
    reader: &NsReader<&[u8]>,
    namespace: Option<&[u8]>,
    start: &BytesStart<'_>,
    empty: bool,
    stack: &mut Vec<Node>,
    root: &Option<Node>,
) -> anyhow::Result<Option<Node>> {
    if root.is_some() {
        return Err(not_svg("content after the root element"));
    }
    let kept = kept_element(namespace, start);
    if stack.is_empty() && kept != Some("svg") {
        return Err(not_svg("the root is not an svg element in the SVG namespace"));
    }
    let Some(name) = kept else { return Ok(None) };
    let node = Node { name, attributes: kept_attributes(reader, start)?, children: Vec::new() };
    if empty {
        return Ok(Some(node));
    }
    if stack.len() >= MAX_DEPTH {
        return Err(not_svg(format!("elements nest deeper than {MAX_DEPTH}")));
    }
    stack.push(node);
    Ok(None)
}

/// The allowlisted name of an element in the SVG namespace, or `None`.
fn kept_element(namespace: Option<&[u8]>, start: &BytesStart<'_>) -> Option<&'static str> {
    if namespace != Some(SVG_NAMESPACE.as_bytes()) {
        return None;
    }
    let local = start.local_name();
    ELEMENTS.iter().copied().find(|name| name.as_bytes() == local.as_ref())
}

fn kept_attributes(
    reader: &NsReader<&[u8]>,
    start: &BytesStart<'_>,
) -> anyhow::Result<Vec<(&'static str, String)>> {
    let mut kept = Vec::new();
    for attribute in start.attributes() {
        let attribute = attribute.map_err(|error| not_svg(format!("{error}")))?;
        let key = attribute.key;
        if key.as_ref() == b"xmlns" || key.as_ref().starts_with(b"xmlns:") {
            continue;
        }
        let value = attribute
            .normalized_value(XmlVersion::Implicit1_0)
            .map_err(|_| not_svg("an attribute uses an undeclared entity"))?;
        let value: String =
            value.chars().map(|ch| if ch.is_control() { ' ' } else { ch }).collect();
        let (namespace, local) = reader.resolver().resolve_attribute(key);
        let name = match namespace {
            ResolveResult::Unbound => {
                ATTRIBUTES.iter().copied().find(|name| name.as_bytes() == local.as_ref())
            }
            ResolveResult::Bound(Namespace(bytes))
                if bytes == XLINK_NAMESPACE.as_bytes() && local.as_ref() == b"href" =>
            {
                Some("xlink:href")
            }
            _ => None,
        };
        let Some(name) = name else { continue };
        let is_href = name == "href" || name == "xlink:href";
        if (is_href && !value.starts_with('#')) || !safe_value(&value) {
            continue;
        }
        kept.push((name, value));
    }
    Ok(kept)
}

/// No scheme, no CSS escape, only allowlisted functions, and every `url()`
/// names an id in this document.
pub fn safe_value(value: &str) -> bool {
    if value.contains(':') || value.contains('\\') {
        return false;
    }
    let bytes = value.as_bytes();
    for (index, _) in value.match_indices('(') {
        let start = bytes[..index]
            .iter()
            .rposition(|byte| !(byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')))
            .map_or(0, |position| position + 1);
        let function = &value[start..index];
        if function.is_empty() {
            continue;
        }
        if !FUNCTIONS.contains(&function) {
            return false;
        }
        if function == "url" {
            let target = value[index + 1..].trim_start().trim_start_matches(['\'', '"']);
            if !target.starts_with('#') {
                return false;
            }
        }
    }
    true
}

fn push_kept_text(stack: &mut [Node], skipping: usize, text: &str) {
    if skipping > 0 {
        return;
    }
    let Some(node) = stack.last_mut() else { return };
    if !TEXT_ELEMENTS.contains(&node.name) {
        return;
    }
    let text: String = text
        .chars()
        .filter_map(|ch| match ch {
            '\r' => Some('\n'),
            '\n' | '\t' => Some(ch),
            ch if ch.is_control() => None,
            ch => Some(ch),
        })
        .collect();
    node.push_text(&text);
}

/// Collect the ids of elements whose subtree holds a `use`. Returns whether
/// `node`'s own subtree holds one.
fn ids_containing_use(node: &Node, ids: &mut HashSet<String>) -> bool {
    let mut contains = node.name == "use";
    for child in &node.children {
        if let Child::Element(child) = child {
            contains |= ids_containing_use(child, ids);
        }
    }
    if contains && let Some((_, id)) = node.attributes.iter().find(|(name, _)| *name == "id") {
        ids.insert(id.clone());
    }
    contains
}

/// Drop every `use` that names an element holding a `use` (itself or an
/// ancestor included). Each kept `use` then copies a subtree without one, so
/// references cannot multiply (the `use` form of entity expansion) or cycle.
fn drop_nested_uses(node: &mut Node, nested: &HashSet<String>) {
    let mut kept = Vec::with_capacity(node.children.len());
    for child in std::mem::take(&mut node.children) {
        match child {
            Child::Element(child) if child.name == "use" && names_any(&child, nested) => {}
            Child::Element(mut child) => {
                drop_nested_uses(&mut child, nested);
                kept.push(Child::Element(child));
            }
            text => kept.push(text),
        }
    }
    node.children = kept;
}

fn names_any(node: &Node, ids: &HashSet<String>) -> bool {
    node.attributes.iter().any(|(name, value)| {
        (*name == "href" || *name == "xlink:href")
            && value.strip_prefix('#').is_some_and(|id| ids.contains(id))
    })
}

fn uses_xlink(node: &Node) -> bool {
    node.attributes.iter().any(|(name, _)| *name == "xlink:href")
        || node.children.iter().any(|child| match child {
            Child::Element(child) => uses_xlink(child),
            Child::Text(_) => false,
        })
}

fn write_node(node: &Node, root: bool, xlink: bool, output: &mut String) {
    output.push('<');
    output.push_str(node.name);
    if root {
        output.push_str(" xmlns=\"");
        output.push_str(SVG_NAMESPACE);
        output.push('"');
        if xlink {
            output.push_str(" xmlns:xlink=\"");
            output.push_str(XLINK_NAMESPACE);
            output.push('"');
        }
    }
    for (name, value) in &node.attributes {
        output.push(' ');
        output.push_str(name);
        output.push_str("=\"");
        output.push_str(&escape(value.as_str()));
        output.push('"');
    }
    if node.children.is_empty() {
        output.push_str("/>");
        return;
    }
    output.push('>');
    for child in &node.children {
        match child {
            Child::Element(child) => write_node(child, false, false, output),
            Child::Text(text) => output.push_str(&escape(text.as_str())),
        }
    }
    output.push_str("</");
    output.push_str(node.name);
    output.push('>');
}

#[cfg(test)]
#[path = "svg_tests.rs"]
mod tests;
