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

/// The sanitized SVG document, or why it was refused.
pub fn sanitize_svg(input: &[u8]) -> anyhow::Result<String> {
    let _ = input;
    Err(invalid_asset("SVG sanitizing is not implemented yet"))
}

/// No scheme, no CSS escape, only allowlisted functions, and every `url()`
/// names an id in this document.
pub fn safe_value(value: &str) -> bool {
    let _ = value;
    false
}

#[cfg(test)]
#[path = "svg_tests.rs"]
mod tests;
