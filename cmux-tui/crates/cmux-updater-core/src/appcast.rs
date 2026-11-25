//! The items of a Sparkle appcast (RSS 2.0 with the `sparkle:` namespace): only the fields the
//! updater decides with; deltas are skipped. This reads a feed the way the app's `XMLParser`
//! delegate did (CmuxNextUpdater `AppcastParser`): element names keep their prefix, a field is
//! the trimmed text of an item's child, the enclosure is the last `<enclosure>` outside
//! `<sparkle:deltas>`, and an item without `sparkle:version` (as a child or on the enclosure) is
//! dropped.

use std::collections::HashMap;

use quick_xml::Reader;
use quick_xml::events::{BytesStart, Event};
use serde::{Deserialize, Serialize};

use crate::system_version::SystemVersion;

/// One `<item>`: the fields that decide whether this Mac is offered the update.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AppcastItem {
    /// `sparkle:version` (the bundle's `CFBundleVersion`).
    pub version: String,
    /// `sparkle:shortVersionString`; the app shows the version when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub minimum_system_version: Option<SystemVersion>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub maximum_system_version: Option<SystemVersion>,
    /// `sparkle:fullReleaseNotesLink`, else `sparkle:releaseNotesLink`, as written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_notes_url: Option<String>,
    /// The enclosure's `url`, as written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub download_url: Option<String>,
    /// `<description>`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_description: Option<String>,
    /// `<pubDate>` (RFC 822), as seconds since 1970.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub date: Option<f64>,
    /// `sparkle:channel`; none is Sparkle's default channel, which every updater accepts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sparkle_channel: Option<String>,
    /// Whether the item lists `sparkle:deltas`.
    #[serde(default)]
    pub lists_deltas: bool,
    /// The enclosure's `sparkle:edSignature` and `length`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signature: Option<ArchiveSignature>,
}

/// The enclosure's EdDSA signature and the length it names.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArchiveSignature {
    pub ed_signature: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub length: Option<i64>,
}

impl AppcastItem {
    /// Whether an updater that allows the `sparkle:channel` tags `channels` sees this item:
    /// untagged items always, tagged ones only when allowed.
    pub fn is_offered<S: AsRef<str>>(&self, channels: &[S]) -> bool {
        self.sparkle_channel
            .as_deref()
            .is_none_or(|channel| channels.iter().any(|allowed| allowed.as_ref() == channel))
    }

    /// Whether Sparkle would offer this item on `system`.
    pub fn supports(&self, system: SystemVersion) -> bool {
        self.minimum_system_version.is_none_or(|minimum| system >= minimum)
            && self.maximum_system_version.is_none_or(|maximum| system <= maximum)
    }
}

/// The appcast was not a readable Sparkle feed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError(pub String);

impl std::fmt::Display for ParseError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for ParseError {}

#[derive(Default)]
struct State {
    items: Vec<AppcastItem>,
    saw_channel: bool,
    fields: Option<HashMap<String, String>>,
    enclosure: Option<HashMap<String, String>>,
    delta_depth: i64,
    lists_deltas: bool,
    text: String,
}

impl State {
    fn start(&mut self, element: &BytesStart<'_>) -> Result<(), ParseError> {
        self.text.clear();
        match element.name().as_ref() {
            b"channel" => self.saw_channel = true,
            b"item" => {
                self.fields = Some(HashMap::new());
                self.enclosure = None;
                self.lists_deltas = false;
            }
            b"sparkle:deltas" => {
                self.delta_depth += 1;
                if self.fields.is_some() {
                    self.lists_deltas = true;
                }
            }
            b"enclosure" if self.fields.is_some() && self.delta_depth == 0 => {
                let mut attributes = HashMap::new();
                for attribute in element.attributes() {
                    let attribute = attribute.map_err(invalid)?;
                    let key =
                        String::from_utf8(attribute.key.as_ref().to_vec()).map_err(invalid)?;
                    let value = attribute.unescape_value().map_err(invalid)?.into_owned();
                    attributes.insert(key, value);
                }
                self.enclosure = Some(attributes);
            }
            _ => {}
        }
        Ok(())
    }

    fn end(&mut self, name: &[u8]) -> Result<(), ParseError> {
        let value = self.text.trim().to_owned();
        self.text.clear();
        match name {
            b"sparkle:deltas" => self.delta_depth -= 1,
            b"item" => self.finish_item(),
            _ => {
                if self.delta_depth == 0 && !value.is_empty() {
                    if let Some(fields) = self.fields.as_mut() {
                        let name = String::from_utf8(name.to_vec()).map_err(invalid)?;
                        fields.insert(name, value);
                    }
                }
            }
        }
        Ok(())
    }

    fn finish_item(&mut self) {
        let Some(mut fields) = self.fields.take() else { return };
        let mut enclosure = self.enclosure.take().unwrap_or_default();
        let Some(version) =
            fields.remove("sparkle:version").or_else(|| enclosure.get("sparkle:version").cloned())
        else {
            return;
        };
        let display_version = fields
            .remove("sparkle:shortVersionString")
            .or_else(|| enclosure.get("sparkle:shortVersionString").cloned());
        let release_notes_url = fields
            .remove("sparkle:fullReleaseNotesLink")
            .or_else(|| fields.remove("sparkle:releaseNotesLink"));
        let signature =
            enclosure.remove("sparkle:edSignature").map(|ed_signature| ArchiveSignature {
                ed_signature,
                length: enclosure.get("length").and_then(|length| swift_int(length)),
            });
        self.items.push(AppcastItem {
            version,
            display_version,
            title: fields.remove("title"),
            minimum_system_version: fields
                .get("sparkle:minimumSystemVersion")
                .and_then(|text| SystemVersion::parse(text)),
            maximum_system_version: fields
                .get("sparkle:maximumSystemVersion")
                .and_then(|text| SystemVersion::parse(text)),
            release_notes_url,
            download_url: enclosure.remove("url"),
            item_description: fields.remove("description"),
            date: fields.get("pubDate").and_then(|text| rfc822(text)),
            sparkle_channel: fields.remove("sparkle:channel"),
            lists_deltas: self.lists_deltas,
            signature,
        });
    }
}

fn invalid(error: impl std::fmt::Display) -> ParseError {
    ParseError(format!("invalid appcast XML: {error}"))
}

/// Swift's `Int(_:)`: an optional sign and ASCII digits, nothing else.
fn swift_int(text: &str) -> Option<i64> {
    let digits = text.strip_prefix(['+', '-']).unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// RSS dates ("Sat, 10 Oct 2026 03:05:21 +0000"), as seconds since 1970.
fn rfc822(text: &str) -> Option<f64> {
    let date =
        time::OffsetDateTime::parse(text, &time::format_description::well_known::Rfc2822).ok()?;
    Some(date.unix_timestamp() as f64)
}

/// Reads the items of `xml`, a Sparkle appcast.
pub fn parse(xml: &str) -> Result<Vec<AppcastItem>, ParseError> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().check_end_names = true;
    let mut state = State::default();
    let mut depth: usize = 0;
    let mut saw_root = false;
    loop {
        match reader.read_event().map_err(invalid)? {
            Event::Start(element) => {
                if depth == 0 && saw_root {
                    return Err(invalid("extra content at the end of the document"));
                }
                depth += 1;
                saw_root = true;
                state.start(&element)?;
            }
            Event::Empty(element) => {
                if depth == 0 && saw_root {
                    return Err(invalid("extra content at the end of the document"));
                }
                saw_root = true;
                state.start(&element)?;
                state.end(element.name().as_ref())?;
            }
            Event::End(element) => {
                depth = depth.saturating_sub(1);
                state.end(element.name().as_ref())?;
            }
            Event::Text(text) => {
                if depth > 0 {
                    state.text.push_str(&text.decode().map_err(invalid)?);
                } else if !text.iter().all(|byte| byte.is_ascii_whitespace()) {
                    return Err(invalid("text outside the root element"));
                }
            }
            Event::GeneralRef(reference) => {
                let name = reference.decode().map_err(invalid)?;
                let resolved = match reference.resolve_char_ref().map_err(invalid)? {
                    Some(character) => character.to_string(),
                    None => match quick_xml::escape::resolve_xml_entity(&name) {
                        Some(entity) => entity.to_owned(),
                        None => return Err(invalid(format!("undeclared entity &{name};"))),
                    },
                };
                if depth > 0 {
                    state.text.push_str(&resolved);
                }
            }
            Event::CData(data) => {
                if depth > 0 {
                    state.text.push_str(&String::from_utf8_lossy(&data));
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    if !saw_root {
        return Err(invalid("the document is empty"));
    }
    if depth != 0 {
        return Err(invalid("the document ends inside an element"));
    }
    if !state.saw_channel {
        return Err(ParseError("appcast has no <channel>".to_owned()));
    }
    Ok(state.items)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FEED: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>cmux NEXT nightly</title>
    <item>
      <title>NEXT 1204</title>
      <pubDate>Sat, 10 Oct 2026 03:05:21 +0000</pubDate>
      <sparkle:version>1204</sparkle:version>
      <sparkle:shortVersionString>1.0.0-nightly.1204</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:channel>cmux-next-canary</sparkle:channel>
      <sparkle:releaseNotesLink>https://cmux.com/notes/short</sparkle:releaseNotesLink>
      <sparkle:fullReleaseNotesLink>https://cmux.com/notes/1204</sparkle:fullReleaseNotesLink>
      <description><![CDATA[New: one &amp; two]]></description>
      <enclosure url="https://files.cmux.com/next/1204.dmg?a=1&amp;b=2" length="123" type="application/octet-stream" sparkle:edSignature="c2ln"/>
      <sparkle:deltas>
        <enclosure url="https://files.cmux.com/next/1203-1204.delta" sparkle:deltaFrom="1203" length="9" sparkle:edSignature="ZGVsdGE="/>
      </sparkle:deltas>
    </item>
    <item>
      <title>NEXT 1203 &amp; friends</title>
      <enclosure url="https://files.cmux.com/next/1203.dmg" sparkle:version="1203" sparkle:shortVersionString="1203s" sparkle:edSignature="eA==" length="+7"/>
      <sparkle:maximumSystemVersion>15.9</sparkle:maximumSystemVersion>
    </item>
    <item><title>no version</title></item>
  </channel>
</rss>"#;

    #[test]
    fn reads_the_fields_the_updater_uses() {
        let items = parse(FEED).unwrap();
        assert_eq!(items.len(), 2);
        let first = &items[0];
        assert_eq!(first.version, "1204");
        assert_eq!(first.display_version.as_deref(), Some("1.0.0-nightly.1204"));
        assert_eq!(first.title.as_deref(), Some("NEXT 1204"));
        assert_eq!(first.minimum_system_version, Some(SystemVersion::new(26, 0, 0)));
        assert_eq!(first.release_notes_url.as_deref(), Some("https://cmux.com/notes/1204"));
        assert_eq!(
            first.download_url.as_deref(),
            Some("https://files.cmux.com/next/1204.dmg?a=1&b=2")
        );
        assert_eq!(first.item_description.as_deref(), Some("New: one &amp; two"));
        assert_eq!(first.date, Some(1_791_601_521.0));
        assert_eq!(first.sparkle_channel.as_deref(), Some("cmux-next-canary"));
        assert!(first.lists_deltas);
        assert_eq!(
            first.signature,
            Some(ArchiveSignature { ed_signature: "c2ln".into(), length: Some(123) })
        );

        let second = &items[1];
        assert_eq!(second.version, "1203");
        assert_eq!(second.display_version.as_deref(), Some("1203s"));
        assert_eq!(second.title.as_deref(), Some("NEXT 1203 & friends"));
        assert_eq!(second.maximum_system_version, Some(SystemVersion::new(15, 9, 0)));
        assert_eq!(second.sparkle_channel, None);
        assert!(!second.lists_deltas);
        assert_eq!(
            second.signature,
            Some(ArchiveSignature { ed_signature: "eA==".into(), length: Some(7) })
        );
    }

    #[test]
    fn a_feed_without_a_channel_is_refused() {
        assert_eq!(parse("<rss></rss>"), Err(ParseError("appcast has no <channel>".into())));
    }

    #[test]
    fn malformed_xml_is_refused() {
        for xml in [
            "",
            "<rss><channel></rss>",
            "<rss><channel>",
            "<rss><channel/></rss><x/>",
            "<rss>&nope;<channel/></rss>",
        ] {
            let error = parse(xml).unwrap_err();
            assert!(error.0.starts_with("invalid appcast XML"), "{xml:?}: {error}");
        }
    }

    #[test]
    fn an_empty_channel_has_no_items() {
        assert_eq!(parse("<rss><channel/></rss>"), Ok(Vec::new()));
    }

    #[test]
    fn a_bad_date_or_system_version_is_left_out() {
        let items = parse(
            "<rss><channel><item><sparkle:version>1</sparkle:version><pubDate>yesterday</pubDate>\
             <sparkle:minimumSystemVersion>twenty-six</sparkle:minimumSystemVersion></item></channel></rss>",
        )
        .unwrap();
        assert_eq!(items[0].date, None);
        assert_eq!(items[0].minimum_system_version, None);
    }

    #[test]
    fn channels_and_systems_decide_what_is_offered() {
        let tagged = AppcastItem {
            version: "1".into(),
            sparkle_channel: Some("cmux-next-dev".into()),
            ..Default::default()
        };
        let untagged = AppcastItem { version: "1".into(), ..Default::default() };
        assert!(untagged.is_offered::<&str>(&[]));
        assert!(!tagged.is_offered(&["cmux-next-canary"]));
        assert!(tagged.is_offered(&["cmux-next-canary", "cmux-next-dev"]));

        let ranged = AppcastItem {
            version: "1".into(),
            minimum_system_version: Some(SystemVersion::new(15, 0, 0)),
            maximum_system_version: Some(SystemVersion::new(26, 0, 0)),
            ..Default::default()
        };
        assert!(!ranged.supports(SystemVersion::new(14, 7, 0)));
        assert!(ranged.supports(SystemVersion::new(15, 0, 0)));
        assert!(ranged.supports(SystemVersion::new(26, 0, 0)));
        assert!(!ranged.supports(SystemVersion::new(26, 0, 1)));
    }
}
