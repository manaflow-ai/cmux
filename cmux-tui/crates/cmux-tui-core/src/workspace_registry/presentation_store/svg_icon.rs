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
//!
//! Containment: every `id` is rewritten into the [`ID_PREFIX`] namespace and
//! every `url(#id)` with it, an attribute whose `url(#id)` names no id of the
//! same icon is dropped, `mask`/`clip-path` inside a mask or clip path are
//! dropped (reference depth at most one), dash patterns and `pathLength` are
//! dropped (renderer CPU), and the root keeps no `width`/`height` (the
//! frontend sizes icons). Frontends still render icons as an isolated image
//! (`<img>`, a data URL, or a native image), never inlined into a DOM
//! (plans/cmux-next/icons.md 1).

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
/// Most elements a renderer draws for masks and clip paths: the sum, over
/// every `mask`/`clip-path` reference, of the referenced subtree's size.
pub(crate) const MAX_SVG_ICON_REFERENCE_WORK: usize = 16 * 1024;

const SVG_NAMESPACE: &str = "http://www.w3.org/2000/svg";
/// Every kept `id` and `url(#id)` target starts with this prefix.
const ID_PREFIX: &str = "cmux-icon-";

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
    /// Inside a `mask` or `clipPath` (including the element itself).
    in_reference: bool,
    /// The prefixed id of a kept `mask` or `clipPath` element.
    reference_id: Option<String>,
}

/// Output under construction: literal markup, or an attribute holding
/// `url(#id)` references that is written only when every target exists.
enum Piece {
    Markup(String),
    Reference { key: &'static str, value: String, targets: Vec<String> },
}

fn push_markup(pieces: &mut Vec<Piece>, text: &str) {
    if let Some(Piece::Markup(last)) = pieces.last_mut() {
        last.push_str(text);
    } else {
        pieces.push(Piece::Markup(text.to_owned()));
    }
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

    let mut pieces: Vec<Piece> = Vec::new();
    let mut ids: std::collections::HashSet<String> = std::collections::HashSet::new();
    // Kept elements in each mask or clip path subtree, by prefixed id.
    let mut reference_sizes: std::collections::HashMap<String, usize> =
        std::collections::HashMap::new();
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
                let in_reference = stack.last().is_some_and(|frame| frame.in_reference)
                    || matches!(kept, Some("mask" | "clipPath"));
                let mut reference_id = None;
                if let Some(name) = kept {
                    for frame in &stack {
                        if let Some(id) = &frame.reference_id {
                            *reference_sizes.entry(id.clone()).or_default() += 1;
                        }
                    }
                    let root = stack.is_empty();
                    let mut open = format!("<{name}");
                    if root {
                        let _ = write!(open, r#" xmlns="{SVG_NAMESPACE}""#);
                    }
                    push_markup(&mut pieces, &open);
                    for attribute in attributes {
                        let key = attribute.key;
                        if (root && matches!(key, "width" | "height"))
                            || (in_reference && matches!(key, "mask" | "clip-path"))
                        {
                            continue;
                        }
                        if matches!(key, "mask" | "clip-path")
                            && !(attribute.targets.len() == 1
                                && attribute.value == format!("url(#{})", attribute.targets[0]))
                        {
                            continue;
                        }
                        if key == "id" {
                            anyhow::ensure!(
                                ids.insert(attribute.value.clone()),
                                "bad request: svg icon defines id {:?} twice",
                                attribute.value
                            );
                            if matches!(name, "mask" | "clipPath") {
                                reference_sizes.insert(attribute.value.clone(), 1);
                                reference_id = Some(attribute.value.clone());
                            }
                        }
                        if attribute.targets.is_empty() {
                            push_markup(&mut pieces, &format!(r#" {key}="{}""#, attribute.value));
                        } else {
                            pieces.push(Piece::Reference {
                                key,
                                value: attribute.value,
                                targets: attribute.targets,
                            });
                        }
                    }
                    push_markup(&mut pieces, ">");
                }
                stack.push(Frame {
                    kept,
                    keeps_text: kept.is_some_and(|name| TEXT_ELEMENTS.contains(&name)),
                    in_reference,
                    reference_id,
                });
            }
            Event::End(_) => {
                let frame =
                    stack.pop().context("bad request: svg icon has an unmatched end tag")?;
                if let Some(name) = frame.kept {
                    push_markup(&mut pieces, &format!("</{name}>"));
                }
            }
            Event::Empty(_) => bail!("bad request: svg icon parser returned an unexpanded element"),
            Event::Text(text) => {
                let text = text
                    .xml10_content()
                    .map_err(|error| anyhow::anyhow!("bad request: svg icon text: {error}"))?;
                push_text(&mut pieces, stack.last(), &text)?;
            }
            Event::CData(data) => {
                let data = data
                    .xml10_content()
                    .map_err(|error| anyhow::anyhow!("bad request: svg icon CDATA: {error}"))?;
                anyhow::ensure!(
                    !stack.is_empty(),
                    "bad request: svg icon has CDATA outside the root"
                );
                push_text(&mut pieces, stack.last(), &data)?;
            }
            Event::GeneralRef(reference) => {
                let ch = resolve_reference(&reference)?;
                push_text(&mut pieces, stack.last(), ch.encode_utf8(&mut [0; 4]))?;
            }
            Event::Eof => break,
        }
    }
    anyhow::ensure!(
        root_seen && stack.is_empty(),
        "bad request: svg icon has no complete <svg> root"
    );
    let mut output = String::with_capacity(text.len());
    let mut reference_work = 0usize;
    for piece in pieces {
        match piece {
            Piece::Markup(markup) => output.push_str(&markup),
            Piece::Reference { key, value, targets } => {
                if targets.iter().all(|target| ids.contains(target)) {
                    if matches!(key, "mask" | "clip-path") {
                        reference_work += targets
                            .iter()
                            .map(|target| reference_sizes.get(target).copied().unwrap_or(0))
                            .sum::<usize>();
                    }
                    let _ = write!(output, r#" {key}="{value}""#);
                }
            }
        }
    }
    anyhow::ensure!(
        reference_work <= MAX_SVG_ICON_REFERENCE_WORK,
        "bad request: svg icon masks and clip paths draw more than {MAX_SVG_ICON_REFERENCE_WORK} elements"
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

/// One kept attribute in canonical form: `value` needs no escaping (it is
/// printable ASCII without `<>"'&`), ids and `url(#id)` targets carry
/// [`ID_PREFIX`], and `targets` lists the ids its `url()`s name.
struct KeptAttribute {
    key: &'static str,
    value: String,
    targets: Vec<String>,
}

/// Every attribute is parsed (so a duplicate, malformed value or unknown
/// entity anywhere refuses the icon); only allowlisted ones with safe values
/// are returned, in document order.
fn read_attributes(start: &BytesStart<'_>) -> anyhow::Result<Vec<KeptAttribute>> {
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
        if name == "id" {
            if is_icon_id(&value) {
                kept.push(KeptAttribute { key: name, value: prefixed_id(&value), targets: vec![] });
            }
        } else if let Some((value, targets)) = canonical_attribute_value(&value) {
            kept.push(KeptAttribute { key: name, value, targets });
        }
    }
    Ok(kept)
}

/// `[A-Za-z_][A-Za-z0-9_.-]*`: an id that is also a valid `url(#id)` target.
fn is_icon_id(id: &str) -> bool {
    id.bytes().next().is_some_and(|first| first.is_ascii_alphabetic() || first == b'_')
        && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
}

/// The id in the icon namespace; already prefixed ids stay as they are, so
/// the output is a fixed point.
fn prefixed_id(id: &str) -> String {
    if id.starts_with(ID_PREFIX) { id.to_owned() } else { format!("{ID_PREFIX}{id}") }
}

/// A presentation or geometry value that cannot reach outside the icon:
/// printable ASCII without quotes, CSS escapes, declarations or at-rules, and
/// only [`ALLOWED_FUNCTIONS`], with `url()` naming a same-document fragment.
/// Returns the value with every `url(...)` rewritten to `url(#<prefixed id>)`
/// and the prefixed ids it names, or `None` to drop the attribute.
fn canonical_attribute_value(value: &str) -> Option<(String, Vec<String>)> {
    if value.len() > MAX_SVG_ICON_BYTES
        || !value.bytes().all(|byte| (0x20..0x7f).contains(&byte))
        || value.bytes().any(|byte| b"\\<>\"'`;{}@!&".contains(&byte))
    {
        return None;
    }
    // Each `(` must consume one `)`, so a surplus `)` is unbalanced.
    if value.matches(')').count() != value.matches('(').count() {
        return None;
    }
    let mut output = String::with_capacity(value.len());
    let mut targets = Vec::new();
    let mut index = 0;
    while let Some(offset) = value[index..].find('(') {
        let open = index + offset;
        let name_start = value[..open]
            .rfind(|ch: char| !(ch.is_ascii_alphanumeric() || ch == '-'))
            .map_or(0, |at| at + 1);
        let name = value[name_start..open].to_ascii_lowercase();
        if !ALLOWED_FUNCTIONS.contains(&name.as_str()) {
            return None;
        }
        let close = value[open..].find(')').map(|at| open + at)?;
        let argument = &value[open + 1..close];
        if argument.contains('(') {
            return None;
        }
        if name == "url" {
            let id = argument.trim_matches(' ').strip_prefix('#')?;
            if !is_icon_id(id) {
                return None;
            }
            let target = prefixed_id(id);
            output.push_str(&value[index..name_start]);
            let _ = write!(output, "url(#{target})");
            targets.push(target);
        } else {
            output.push_str(&value[index..=close]);
        }
        index = close + 1;
    }
    output.push_str(&value[index..]);
    Some((output, targets))
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

/// A character that may appear in icon text: an XML 1.0 `Char` other than a
/// control character (tab, LF and CR excepted), and no bidi override or
/// isolate, and no invisible format character other than ZWJ (the text can
/// become a tooltip or accessibility label).
fn is_allowed_text_char(ch: char) -> bool {
    (!ch.is_control() || matches!(ch, '\t' | '\n' | '\r'))
        && !matches!(
            ch,
            '\u{FFFE}'
                | '\u{FFFF}'
                | '\u{00AD}'
                | '\u{061C}'
                | '\u{180E}'
                | '\u{200B}'
                | '\u{200C}'
                | '\u{200E}'..='\u{200F}'
                | '\u{2028}'..='\u{202E}'
                | '\u{2060}'..='\u{206F}'
                | '\u{FEFF}'
                | '\u{FFF9}'..='\u{FFFB}'
                | '\u{E0000}'..='\u{E007F}'
        )
}

/// Character data: whitespace only outside the root, kept (escaped) only in a
/// kept text element. A CR is written as `&#13;`, because a raw CR would be
/// normalized to LF when the output is parsed again.
fn push_text(pieces: &mut Vec<Piece>, frame: Option<&Frame>, text: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        text.chars().all(is_allowed_text_char),
        "bad request: svg icon text contains a control, noncharacter or bidi override character"
    );
    match frame {
        None => anyhow::ensure!(
            text.chars().all(|ch| ch.is_ascii_whitespace()),
            "bad request: svg icon has text outside the root element"
        ),
        Some(frame) if frame.keeps_text && frame.kept.is_some() => {
            push_markup(pieces, &escape(text).replace('\r', "&#13;"));
        }
        Some(_) => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests;
