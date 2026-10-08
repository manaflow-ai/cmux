//! SVG icon sanitizer (plans/cmux-next/icons.md 1, decision D1).
//!
//! An SVG icon is untrusted markup that every frontend renders, so the owner
//! never stores what a client sent. It parses the bytes with a real XML parser
//! (quick-xml, which never reads a DTD and never expands a custom entity),
//! keeps only allowlisted elements and attributes, and writes a new document
//! from what it kept. The output is a fixed point: sanitizing it again returns
//! the same bytes, so the asset's digest names exactly the stored form.
//!
//! Refused outright: anything over 64 KiB (input or output), a DOCTYPE,
//! any entity reference other than the five XML ones and character
//! references, a root other than `svg`, malformed XML, a non-UTF-8 encoding,
//! control characters, more than [`MAX_SVG_ICON_DEPTH`] levels or
//! [`MAX_SVG_ICON_ELEMENTS`] elements. Dropped silently: every element or
//! attribute outside the allowlist (with the element's whole subtree),
//! comments, processing instructions, every namespace declaration, and every
//! attribute value that could reach outside the icon (`url()` other than
//! `url(#id)`, any CSS escape or function outside a small paint and transform
//! set). No `href` of any kind survives.

use anyhow::{Context, bail};
use quick_xml::Reader;
use quick_xml::XmlVersion;
use quick_xml::escape::escape;
use quick_xml::events::{BytesStart, Event};
use sha2::{Digest, Sha256};
use std::fmt::Write as _;

/// Largest accepted SVG icon asset, before and after sanitizing.
pub const MAX_SVG_ICON_BYTES: usize = 64 * 1024;
/// Deepest accepted element nesting, counting the root and dropped elements.
pub(crate) const MAX_SVG_ICON_DEPTH: usize = 32;
/// Most elements accepted in one icon, counting the root and dropped elements.
pub(crate) const MAX_SVG_ICON_ELEMENTS: usize = 4096;

const SVG_NAMESPACE: &str = "http://www.w3.org/2000/svg";

/// Static shapes, grouping, gradients, clipping, masking and text. No
/// scripting, links, `use`, images, filters, patterns, styles, animation,
/// `foreignObject` or fonts: each of those can run code, load a resource or
/// amplify rendering work.
const ALLOWED_ELEMENTS: &[&str] = &[
    "svg",
    "g",
    "defs",
    "title",
    "desc",
    "path",
    "rect",
    "circle",
    "ellipse",
    "line",
    "polyline",
    "polygon",
    "text",
    "tspan",
    "linearGradient",
    "radialGradient",
    "stop",
    "clipPath",
    "mask",
];

/// Elements whose character data is kept.
const TEXT_ELEMENTS: &[&str] = &["title", "desc", "text", "tspan"];

/// Geometry and presentation attributes. No `style`, `class`, `href`,
/// `xlink:*`, `xml:*`, event handlers or animation targets.
const ALLOWED_ATTRIBUTES: &[&str] = &[
    "id",
    "d",
    "x",
    "y",
    "x1",
    "y1",
    "x2",
    "y2",
    "cx",
    "cy",
    "r",
    "rx",
    "ry",
    "fx",
    "fy",
    "fr",
    "dx",
    "dy",
    "width",
    "height",
    "viewBox",
    "preserveAspectRatio",
    "points",
    "pathLength",
    "transform",
    "offset",
    "gradientUnits",
    "gradientTransform",
    "spreadMethod",
    "clipPathUnits",
    "maskUnits",
    "maskContentUnits",
    "fill",
    "fill-opacity",
    "fill-rule",
    "stroke",
    "stroke-width",
    "stroke-linecap",
    "stroke-linejoin",
    "stroke-miterlimit",
    "stroke-dasharray",
    "stroke-dashoffset",
    "stroke-opacity",
    "opacity",
    "color",
    "clip-path",
    "clip-rule",
    "mask",
    "stop-color",
    "stop-opacity",
    "display",
    "visibility",
    "vector-effect",
    "shape-rendering",
    "paint-order",
    "font-size",
    "font-weight",
    "font-style",
    "text-anchor",
    "dominant-baseline",
    "letter-spacing",
];

/// CSS functions an attribute value may call. `url` is further limited to a
/// same-document fragment.
const ALLOWED_FUNCTIONS: &[&str] = &[
    "url",
    "matrix",
    "translate",
    "scale",
    "rotate",
    "skewx",
    "skewy",
    "rgb",
    "rgba",
    "hsl",
    "hsla",
];

struct Frame {
    /// The canonical element name when it is written to the output.
    kept: Option<&'static str>,
    keeps_text: bool,
}

/// Sanitize an SVG icon into its canonical stored form (see the module docs).
pub fn sanitize_svg_icon(input: &[u8]) -> anyhow::Result<String> {
    anyhow::ensure!(
        input.len() <= MAX_SVG_ICON_BYTES,
        "bad request: svg icon exceeds 64 KiB ({} bytes)",
        input.len()
    );
    let text = std::str::from_utf8(input).context("bad request: svg icon is not UTF-8")?;
    let text = text.strip_prefix('\u{FEFF}').unwrap_or(text);
    let mut reader = Reader::from_str(text);
    let config = reader.config_mut();
    config.expand_empty_elements = true;
    config.check_end_names = true;
    config.check_comments = true;
    config.allow_dangling_amp = false;
    config.allow_unmatched_ends = false;

    let mut output = String::with_capacity(text.len());
    let mut stack: Vec<Frame> = Vec::new();
    let mut elements = 0usize;
    let mut root_seen = false;
    loop {
        let event = reader.read_event().map_err(|error| {
            anyhow::anyhow!("bad request: svg icon is not well-formed XML: {error}")
        })?;
        match event {
            Event::Decl(decl) => {
                anyhow::ensure!(
                    !root_seen,
                    "bad request: svg icon has a misplaced XML declaration"
                );
                if let Some(encoding) = decl.encoding() {
                    let encoding =
                        encoding.context("bad request: svg icon XML declaration is malformed")?;
                    anyhow::ensure!(
                        encoding.eq_ignore_ascii_case(b"utf-8"),
                        "bad request: svg icon must be UTF-8"
                    );
                }
            }
            Event::DocType(_) => bail!("bad request: svg icon may not contain a DOCTYPE"),
            Event::PI(_) | Event::Comment(_) => {}
            Event::Start(start) => {
                elements += 1;
                anyhow::ensure!(
                    elements <= MAX_SVG_ICON_ELEMENTS,
                    "bad request: svg icon has more than {MAX_SVG_ICON_ELEMENTS} elements"
                );
                anyhow::ensure!(
                    stack.len() < MAX_SVG_ICON_DEPTH,
                    "bad request: svg icon nests deeper than {MAX_SVG_ICON_DEPTH} elements"
                );
                if stack.is_empty() {
                    anyhow::ensure!(
                        !root_seen,
                        "bad request: svg icon has more than one root element"
                    );
                    anyhow::ensure!(
                        start.name().as_ref() == b"svg",
                        "bad request: svg icon root must be an unprefixed <svg> element"
                    );
                    root_seen = true;
                }
                let attributes = read_attributes(&start)?;
                let parent_kept = stack.last().is_none_or(|frame| frame.kept.is_some());
                let kept = parent_kept.then(|| allowed_element(start.name().as_ref())).flatten();
                if let Some(name) = kept {
                    output.push('<');
                    output.push_str(name);
                    if stack.is_empty() {
                        let _ = write!(output, r#" xmlns="{SVG_NAMESPACE}""#);
                    }
                    for (key, value) in attributes {
                        let _ = write!(output, r#" {key}="{}""#, escape(value.as_str()));
                    }
                    output.push('>');
                }
                stack.push(Frame {
                    kept,
                    keeps_text: kept.is_some_and(|name| TEXT_ELEMENTS.contains(&name)),
                });
            }
            Event::End(_) => {
                let frame =
                    stack.pop().context("bad request: svg icon has an unmatched end tag")?;
                if let Some(name) = frame.kept {
                    let _ = write!(output, "</{name}>");
                }
            }
            Event::Empty(_) => bail!("bad request: svg icon parser returned an unexpanded element"),
            Event::Text(text) => {
                let text = text
                    .xml10_content()
                    .map_err(|error| anyhow::anyhow!("bad request: svg icon text: {error}"))?;
                push_text(&mut output, stack.last(), &text)?;
            }
            Event::CData(data) => {
                let data = data
                    .xml10_content()
                    .map_err(|error| anyhow::anyhow!("bad request: svg icon CDATA: {error}"))?;
                anyhow::ensure!(
                    !stack.is_empty(),
                    "bad request: svg icon has CDATA outside the root"
                );
                push_text(&mut output, stack.last(), &data)?;
            }
            Event::GeneralRef(reference) => {
                let ch = resolve_reference(&reference)?;
                push_text(&mut output, stack.last(), ch.encode_utf8(&mut [0; 4]))?;
            }
            Event::Eof => break,
        }
    }
    anyhow::ensure!(
        root_seen && stack.is_empty(),
        "bad request: svg icon has no complete <svg> root"
    );
    anyhow::ensure!(
        output.len() <= MAX_SVG_ICON_BYTES,
        "bad request: sanitized svg icon exceeds 64 KiB ({} bytes)",
        output.len()
    );
    Ok(output)
}

/// The icon wire string (`svg:sha256-<64 hex>`) naming sanitized SVG text.
pub fn svg_icon_wire(sanitized: &str) -> String {
    let digest = Sha256::digest(sanitized.as_bytes());
    let mut wire = String::with_capacity(11 + 64);
    wire.push_str("svg:sha256-");
    for byte in digest {
        let _ = write!(wire, "{byte:02x}");
    }
    wire
}

fn allowed_element(name: &[u8]) -> Option<&'static str> {
    ALLOWED_ELEMENTS.iter().copied().find(|allowed| allowed.as_bytes() == name)
}

/// Every attribute is parsed (so a duplicate, malformed value or unknown
/// entity anywhere refuses the icon); only allowlisted ones with safe values
/// are returned, in document order.
fn read_attributes(start: &BytesStart<'_>) -> anyhow::Result<Vec<(&'static str, String)>> {
    let mut kept = Vec::new();
    for attribute in start.attributes() {
        let attribute = attribute.map_err(|error| {
            anyhow::anyhow!("bad request: svg icon attribute is malformed: {error}")
        })?;
        let value = attribute.normalized_value(XmlVersion::Implicit1_0).map_err(|error| {
            anyhow::anyhow!(
                "bad request: svg icon attribute value (entity or character reference): {error}"
            )
        })?;
        let key = attribute.key.as_ref();
        let Some(name) =
            ALLOWED_ATTRIBUTES.iter().copied().find(|allowed| allowed.as_bytes() == key)
        else {
            continue;
        };
        if attribute_value_is_safe(&value) {
            kept.push((name, value.into_owned()));
        }
    }
    Ok(kept)
}

/// A presentation or geometry value that cannot reach outside the icon:
/// printable ASCII without quotes, CSS escapes, declarations or at-rules, and
/// only [`ALLOWED_FUNCTIONS`], with `url()` naming a same-document fragment.
fn attribute_value_is_safe(value: &str) -> bool {
    if value.len() > MAX_SVG_ICON_BYTES
        || !value.bytes().all(|byte| (0x20..0x7f).contains(&byte))
        || value.bytes().any(|byte| b"\\<>\"'`;{}@!&".contains(&byte))
    {
        return false;
    }
    let mut index = 0;
    while let Some(offset) = value[index..].find('(') {
        let open = index + offset;
        let name_start = value[..open]
            .rfind(|ch: char| !(ch.is_ascii_alphanumeric() || ch == '-'))
            .map_or(0, |at| at + 1);
        let name = value[name_start..open].to_ascii_lowercase();
        if !ALLOWED_FUNCTIONS.contains(&name.as_str()) {
            return false;
        }
        let Some(close) = value[open..].find(')').map(|at| open + at) else {
            return false;
        };
        let argument = &value[open + 1..close];
        if argument.contains('(') {
            return false;
        }
        if name == "url" {
            let target = argument.trim_matches(' ');
            let Some(id) = target.strip_prefix('#') else {
                return false;
            };
            if id.is_empty()
                || !id
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
            {
                return false;
            }
        }
        index = close + 1;
    }
    // Each `(` consumed one `)`, so a surplus `)` is unbalanced.
    value.matches(')').count() == value.matches('(').count()
}

/// The five XML entities and character references; anything else (an entity a
/// DTD would have declared) refuses the icon.
fn resolve_reference(reference: &quick_xml::events::BytesRef<'_>) -> anyhow::Result<char> {
    if let Some(ch) = reference
        .resolve_char_ref()
        .map_err(|error| anyhow::anyhow!("bad request: svg icon character reference: {error}"))?
    {
        return Ok(ch);
    }
    match &**reference {
        b"lt" => Ok('<'),
        b"gt" => Ok('>'),
        b"amp" => Ok('&'),
        b"apos" => Ok('\''),
        b"quot" => Ok('"'),
        other => bail!(
            "bad request: svg icon uses an undeclared entity &{};",
            String::from_utf8_lossy(other)
        ),
    }
}

/// Character data: whitespace only outside the root, kept (escaped) only in a
/// kept text element, and never a control character other than tab, CR or LF.
fn push_text(output: &mut String, frame: Option<&Frame>, text: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !text.chars().any(|ch| ch.is_control() && !matches!(ch, '\t' | '\n' | '\r')),
        "bad request: svg icon text contains a control character"
    );
    match frame {
        None => anyhow::ensure!(
            text.chars().all(|ch| ch.is_ascii_whitespace()),
            "bad request: svg icon has text outside the root element"
        ),
        Some(frame) if frame.keeps_text && frame.kept.is_some() => output.push_str(&escape(text)),
        Some(_) => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests;
