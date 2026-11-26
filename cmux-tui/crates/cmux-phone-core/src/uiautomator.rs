//! `uiautomator dump` XML as a phone element tree, frames in dp (Swift
//! `UIAutomatorTree`). The dump is flat XML: `hierarchy` and `node` elements
//! whose facts are attributes, so a small reader serves it without an XML
//! library in the app.
use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Frame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

const ZERO: Frame = Frame { x: 0.0, y: 0.0, width: 0.0, height: 0.0 };

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Element {
    pub role: String,
    pub label: String,
    pub identifier: String,
    pub value: String,
    pub frame: Frame,
    pub children: Vec<Element>,
}

impl Element {
    fn new(role: String, label: String, identifier: String, frame: Frame) -> Self {
        Self { role, label, identifier, value: String::new(), frame, children: Vec::new() }
    }
}

/// The dump could not be read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Unreadable;

/// "[105,525][420,630]" -> a rect in dp.
pub fn frame(bounds: &str, pixels_per_point: f64) -> Frame {
    let numbers: Vec<f64> = bounds
        .split(|ch: char| !ch.is_numeric() && ch != '-')
        .filter(|part| !part.is_empty())
        .filter_map(|part| part.parse().ok())
        .collect();
    if numbers.len() != 4 {
        return ZERO;
    }
    let s = pixels_per_point;
    Frame {
        x: numbers[0] / s,
        y: numbers[1] / s,
        width: (numbers[2] - numbers[0]) / s,
        height: (numbers[3] - numbers[1]) / s,
    }
}

fn decode_entities(text: &str) -> Result<String, Unreadable> {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        let after = &rest[amp + 1..];
        let semi = after.find(';').ok_or(Unreadable)?;
        let name = &after[..semi];
        let ch = match name {
            "amp" => '&',
            "lt" => '<',
            "gt" => '>',
            "quot" => '"',
            "apos" => '\'',
            _ => {
                let code = if let Some(hex) =
                    name.strip_prefix("#x").or_else(|| name.strip_prefix("#X"))
                {
                    u32::from_str_radix(hex, 16).map_err(|_| Unreadable)?
                } else if let Some(decimal) = name.strip_prefix('#') {
                    decimal.parse().map_err(|_| Unreadable)?
                } else {
                    return Err(Unreadable);
                };
                char::from_u32(code).ok_or(Unreadable)?
            }
        };
        out.push(ch);
        rest = &after[semi + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

/// The attributes of a start tag's body (after its name).
fn attributes(mut body: &str) -> Result<Vec<(String, String)>, Unreadable> {
    let mut out = Vec::new();
    loop {
        body = body.trim_start();
        if body.is_empty() {
            return Ok(out);
        }
        let eq = body.find('=').ok_or(Unreadable)?;
        let name = body[..eq].trim();
        if name.is_empty() || name.contains(char::is_whitespace) {
            return Err(Unreadable);
        }
        let value = body[eq + 1..].trim_start();
        let quote =
            value.chars().next().filter(|ch| *ch == '"' || *ch == '\'').ok_or(Unreadable)?;
        let end = value[1..].find(quote).ok_or(Unreadable)?;
        let raw = &value[1..1 + end];
        if raw.contains('<') {
            return Err(Unreadable);
        }
        // XML normalizes literal whitespace characters in attribute values to spaces.
        let normalized = raw.replace(['\n', '\r', '\t'], " ");
        out.push((name.to_owned(), decode_entities(&normalized)?));
        body = &value[1 + end + 1..];
    }
}

fn attribute<'a>(attributes: &'a [(String, String)], name: &str) -> Option<&'a str> {
    attributes.iter().find(|(key, _)| key == name).map(|(_, value)| value.as_str())
}

/// Parses a dump; `pixels_per_point` is the screen's pixels per dp.
pub fn parse(output: &str, pixels_per_point: f64) -> Result<Element, Unreadable> {
    // The dump ends with a status line after the XML ("UI hierchary dumped to: /dev/tty").
    let text = match output.rfind("</hierarchy>") {
        Some(end) => &output[..end + "</hierarchy>".len()],
        None => output,
    };
    let scale = pixels_per_point.max(0.01);
    let mut stack: Vec<Element> = Vec::new();
    let mut root: Option<Element> = None;
    let mut open: Vec<String> = Vec::new();
    let mut rest = text;
    while let Some(lt) = rest.find('<') {
        if !rest[..lt].trim().is_empty() && open.is_empty() {
            return Err(Unreadable);
        }
        let tag = &rest[lt..];
        if let Some(body) = tag.strip_prefix("<?") {
            let end = body.find("?>").ok_or(Unreadable)?;
            rest = &body[end + 2..];
            continue;
        }
        if let Some(body) = tag.strip_prefix("<!--") {
            let end = body.find("-->").ok_or(Unreadable)?;
            rest = &body[end + 3..];
            continue;
        }
        let gt = tag.find('>').ok_or(Unreadable)?;
        let inner = &tag[1..gt];
        rest = &tag[gt + 1..];
        if let Some(name) = inner.strip_prefix('/') {
            let name = name.trim();
            if open.pop().as_deref() != Some(name) {
                return Err(Unreadable);
            }
            end_element(name, &mut stack, &mut root);
            continue;
        }
        if inner.starts_with('!') {
            continue;
        }
        let (inner, closes) = match inner.strip_suffix('/') {
            Some(inner) => (inner, true),
            None => (inner, false),
        };
        let name_end = inner.find(char::is_whitespace).unwrap_or(inner.len());
        let name = &inner[..name_end];
        if name.is_empty() || (open.is_empty() && root.is_some()) {
            return Err(Unreadable);
        }
        let attributes = attributes(&inner[name_end..])?;
        match name {
            "hierarchy" => {
                stack.push(Element::new("Screen".into(), String::new(), String::new(), ZERO));
            }
            "node" => {
                let role = attribute(&attributes, "class").unwrap_or("View");
                let role =
                    role.split('.').rfind(|part| !part.is_empty()).unwrap_or("View").to_owned();
                let text = attribute(&attributes, "text").unwrap_or("");
                let label = if text.is_empty() {
                    attribute(&attributes, "content-desc").unwrap_or("")
                } else {
                    text
                };
                stack.push(Element::new(
                    role,
                    label.to_owned(),
                    attribute(&attributes, "resource-id").unwrap_or("").to_owned(),
                    frame(attribute(&attributes, "bounds").unwrap_or(""), scale),
                ));
            }
            _ => {}
        }
        if closes {
            end_element(name, &mut stack, &mut root);
        } else {
            open.push(name.to_owned());
        }
    }
    if !open.is_empty() || !rest.trim().is_empty() {
        return Err(Unreadable);
    }
    root.ok_or(Unreadable)
}

fn end_element(name: &str, stack: &mut Vec<Element>, root: &mut Option<Element>) {
    if name != "node" && name != "hierarchy" {
        return;
    }
    let Some(done) = stack.pop() else { return };
    match stack.last_mut() {
        Some(parent) => parent.children.push(done),
        None => *root = Some(done),
    }
}
