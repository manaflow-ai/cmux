//! A Sparkle appcast (RSS 2.0 with the `sparkle:` namespace): the fields of
//! each `<item>` that decide whether this Mac is offered the update.
//!
//! The parser mirrors the app's former `XMLParser` reader: names are read as
//! written (no namespace processing), an element's text is what follows its
//! last child (text resets at every start and end tag), enclosures inside
//! `<sparkle:deltas>` are skipped, and a document that is not well-formed XML
//! or has no `<channel>` is an error. Only UTF-8 documents are read.

use crate::civil;
use crate::version::{SystemVersion, is_whitespace_or_newline};
use quick_xml::XmlVersion;
use quick_xml::events::{BytesStart, Event};
use quick_xml::{Reader, escape};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// One `<item>` of an appcast.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppcastItem {
    /// `sparkle:version` (the bundle's `CFBundleVersion`).
    pub version: String,
    /// `sparkle:shortVersionString`, else the version.
    pub display_version: String,
    #[serde(default)]
    pub title: Option<String>,
    /// `sparkle:minimumSystemVersion`; none offers the item to every macOS.
    #[serde(default)]
    pub minimum_system_version: Option<SystemVersion>,
    /// `sparkle:maximumSystemVersion`.
    #[serde(default)]
    pub maximum_system_version: Option<SystemVersion>,
    /// `sparkle:fullReleaseNotesLink`, else `sparkle:releaseNotesLink`, as
    /// written (the app makes the URL).
    #[serde(default)]
    pub release_notes_url: Option<String>,
    /// The enclosure's `url`, as written.
    #[serde(default)]
    pub download_url: Option<String>,
    /// The item's `<description>`.
    #[serde(default)]
    pub item_description: Option<String>,
    /// `<pubDate>`, seconds since 1970 (Swift `Date.timeIntervalSince1970`).
    #[serde(default)]
    pub date: Option<f64>,
    /// `sparkle:channel`; none is Sparkle's default channel, which every updater accepts.
    #[serde(default)]
    pub sparkle_channel: Option<String>,
    /// Whether the item lists `sparkle:deltas`.
    #[serde(default)]
    pub lists_deltas: bool,
}

impl AppcastItem {
    /// An item with only a version (the display version is the version).
    pub fn new(version: &str) -> Self {
        Self {
            version: version.to_owned(),
            display_version: version.to_owned(),
            title: None,
            minimum_system_version: None,
            maximum_system_version: None,
            release_notes_url: None,
            download_url: None,
            item_description: None,
            date: None,
            sparkle_channel: None,
            lists_deltas: false,
        }
    }

    /// Whether an updater that allows the `sparkle:channel` tags `channels`
    /// sees this item: untagged items always, tagged ones only when allowed.
    pub fn is_offered(&self, channels: &BTreeSet<String>) -> bool {
        self.sparkle_channel.as_ref().is_none_or(|channel| channels.contains(channel))
    }

    /// Whether Sparkle would offer this item on `system`.
    pub fn supports(&self, system: SystemVersion) -> bool {
        if self.minimum_system_version.is_some_and(|minimum| system < minimum) {
            return false;
        }
        if self.maximum_system_version.is_some_and(|maximum| system > maximum) {
            return false;
        }
        true
    }
}

/// The appcast was not a readable Sparkle feed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppcastParseError {
    pub message: String,
}

impl std::fmt::Display for AppcastParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

fn error(message: impl Into<String>) -> AppcastParseError {
    AppcastParseError { message: message.into() }
}

fn xml_error(cause: impl Into<quick_xml::Error>) -> AppcastParseError {
    error(format!("invalid appcast XML: {}", cause.into()))
}

/// XML's `Char` production: what a well-formed document may hold.
fn is_xml_char(c: char) -> bool {
    matches!(c, '\u{9}' | '\u{A}' | '\u{D}' | '\u{20}'..='\u{D7FF}' | '\u{E000}'..='\u{FFFD}' | '\u{10000}'..)
}

fn checked(text: &str) -> Result<&str, AppcastParseError> {
    if text.chars().all(is_xml_char) {
        Ok(text)
    } else {
        Err(error("invalid appcast XML: a character XML does not allow"))
    }
}

/// XML white space (allowed outside the root element).
fn is_xml_space(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\r' | '\n')
}

/// The `XMLParser` callbacks: collects `<item>` children, ignoring the
/// enclosures inside `<sparkle:deltas>`.
#[derive(Default)]
struct Collector {
    items: Vec<AppcastItem>,
    saw_channel: bool,
    fields: Option<BTreeMap<String, String>>,
    enclosure: Option<BTreeMap<String, String>>,
    delta_depth: i64,
    lists_deltas: bool,
    text: String,
}

impl Collector {
    fn start(&mut self, name: &str, attributes: BTreeMap<String, String>) {
        self.text.clear();
        match name {
            "channel" => self.saw_channel = true,
            "item" => {
                self.fields = Some(BTreeMap::new());
                self.enclosure = None;
                self.lists_deltas = false;
            }
            "sparkle:deltas" => {
                self.delta_depth = self.delta_depth.saturating_add(1);
                if self.fields.is_some() {
                    self.lists_deltas = true;
                }
            }
            "enclosure" if self.fields.is_some() && self.delta_depth == 0 => {
                self.enclosure = Some(attributes)
            }
            _ => {}
        }
    }

    fn end(&mut self, name: &str) {
        let value = self.text.trim_matches(is_whitespace_or_newline).to_owned();
        self.text.clear();
        match name {
            "sparkle:deltas" => self.delta_depth = self.delta_depth.saturating_sub(1),
            "item" => self.finish_item(),
            _ => {
                if self.delta_depth == 0
                    && !value.is_empty()
                    && let Some(fields) = self.fields.as_mut()
                {
                    fields.insert(name.to_owned(), value);
                }
            }
        }
    }

    fn finish_item(&mut self) {
        let Some(fields) = self.fields.take() else { return };
        let empty = BTreeMap::new();
        let enclosure = self.enclosure.as_ref().unwrap_or(&empty);
        let field = |name: &str| fields.get(name).cloned();
        let Some(version) =
            field("sparkle:version").or_else(|| enclosure.get("sparkle:version").cloned())
        else {
            return;
        };
        let display_version = field("sparkle:shortVersionString")
            .or_else(|| enclosure.get("sparkle:shortVersionString").cloned())
            .unwrap_or_else(|| version.clone());
        self.items.push(AppcastItem {
            display_version,
            title: field("title"),
            minimum_system_version: fields
                .get("sparkle:minimumSystemVersion")
                .and_then(|v| SystemVersion::parse(v)),
            maximum_system_version: fields
                .get("sparkle:maximumSystemVersion")
                .and_then(|v| SystemVersion::parse(v)),
            release_notes_url: field("sparkle:fullReleaseNotesLink")
                .or_else(|| field("sparkle:releaseNotesLink")),
            download_url: enclosure.get("url").cloned(),
            item_description: field("description"),
            date: fields.get("pubDate").and_then(|v| civil::parse_rfc822(v)),
            sparkle_channel: field("sparkle:channel"),
            lists_deltas: self.lists_deltas,
            version,
        });
    }
}

fn element_name(start: &BytesStart<'_>) -> Result<String, AppcastParseError> {
    std::str::from_utf8(start.name().as_ref())
        .map(str::to_owned)
        .map_err(|_| error("invalid appcast XML: a name is not UTF-8"))
}

/// Every attribute of `start`, normalized as XML 1.0 asks (entities resolved,
/// tab and line breaks read as spaces). A malformed or repeated attribute is an error.
fn attributes(start: &BytesStart<'_>) -> Result<BTreeMap<String, String>, AppcastParseError> {
    let mut map = BTreeMap::new();
    for attribute in start.attributes() {
        let attribute = attribute.map_err(xml_error)?;
        let key = std::str::from_utf8(attribute.key.as_ref())
            .map_err(|_| error("invalid appcast XML: a name is not UTF-8"))?;
        let value = attribute.normalized_value(XmlVersion::Implicit1_0).map_err(xml_error)?;
        map.insert(key.to_owned(), checked(&value)?.to_owned());
    }
    Ok(map)
}

/// The items of an appcast document, in feed order.
pub fn parse(data: &[u8]) -> Result<Vec<AppcastItem>, AppcastParseError> {
    let text = std::str::from_utf8(data).map_err(|_| error("appcast is not UTF-8"))?;
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut reader = Reader::from_str(text);
    let mut collector = Collector::default();
    let mut depth: usize = 0;
    let mut root_closed = false;
    loop {
        match reader.read_event().map_err(xml_error)? {
            Event::Eof => break,
            Event::Start(start) => {
                if depth == 0 && root_closed {
                    return Err(error("invalid appcast XML: content after the root element"));
                }
                let name = element_name(&start)?;
                let attributes = attributes(&start)?;
                depth = depth.saturating_add(1);
                collector.start(&name, attributes);
            }
            Event::Empty(start) => {
                if depth == 0 && root_closed {
                    return Err(error("invalid appcast XML: content after the root element"));
                }
                let name = element_name(&start)?;
                let attributes = attributes(&start)?;
                collector.start(&name, attributes);
                collector.end(&name);
                if depth == 0 {
                    root_closed = true;
                }
            }
            Event::End(end) => {
                let name = std::str::from_utf8(end.name().as_ref())
                    .map_err(|_| error("invalid appcast XML: a name is not UTF-8"))?
                    .to_owned();
                depth = depth
                    .checked_sub(1)
                    .ok_or_else(|| error("invalid appcast XML: an end tag without a start"))?;
                collector.end(&name);
                if depth == 0 {
                    root_closed = true;
                }
            }
            Event::Text(content) => {
                let content = content.xml10_content().map_err(xml_error)?;
                if depth == 0 {
                    if !content.chars().all(is_xml_space) {
                        return Err(error("invalid appcast XML: text outside the root element"));
                    }
                } else {
                    collector.text.push_str(checked(&content)?);
                }
            }
            Event::CData(content) => {
                if depth == 0 {
                    return Err(error("invalid appcast XML: CDATA outside the root element"));
                }
                let content = content.xml10_content().map_err(xml_error)?;
                collector.text.push_str(checked(&content)?);
            }
            Event::GeneralRef(reference) => {
                if depth == 0 {
                    return Err(error("invalid appcast XML: a reference outside the root element"));
                }
                if let Some(c) = reference.resolve_char_ref().map_err(xml_error)? {
                    if !is_xml_char(c) {
                        return Err(error("invalid appcast XML: a character XML does not allow"));
                    }
                    collector.text.push(c);
                } else {
                    let name = reference.decode().map_err(xml_error)?;
                    let value = escape::resolve_xml_entity(&name).ok_or_else(|| {
                        error(format!("invalid appcast XML: undefined entity &{name};"))
                    })?;
                    collector.text.push_str(value);
                }
            }
            Event::Comment(_) | Event::Decl(_) | Event::PI(_) | Event::DocType(_) => {}
        }
    }
    if depth != 0 {
        return Err(error("invalid appcast XML: an element is not closed"));
    }
    if !root_closed {
        return Err(error("invalid appcast XML: no root element"));
    }
    if !collector.saw_channel {
        return Err(error("appcast has no <channel>"));
    }
    Ok(collector.items)
}

/// The items an updater that allows `channels` sees, in feed order (`None`
/// sees every item).
pub fn offered(items: Vec<AppcastItem>, channels: Option<&BTreeSet<String>>) -> Vec<AppcastItem> {
    match channels {
        Some(channels) => items.into_iter().filter(|item| item.is_offered(channels)).collect(),
        None => items,
    }
}
