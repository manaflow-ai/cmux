//! One metadata-only chat of acpmux's device-wide index, and its lenient wire decode.
//!
//! The decode matches the Swift decoder it replaces (`AcpmuxChat(json:)`): a
//! field of the wrong type reads as absent instead of failing the whole line,
//! unknown fields are ignored, and `key`, `sessionId` and `harness` must be
//! non-empty strings.

use serde::de::{Deserialize, Deserializer, IgnoredAny, MapAccess, SeqAccess, Visitor};
use std::fmt;

/// One chat as the app shows it.
#[derive(Clone, Debug, PartialEq)]
pub struct Chat {
    /// `<harness>:<session id>`, unique in the index.
    pub key: Box<str>,
    pub session_id: Box<str>,
    pub harness: Box<str>,
    /// None when absent or empty.
    pub title: Option<Box<str>>,
    /// None when absent or empty.
    pub cwd: Option<Box<str>>,
    pub created_ms: Option<f64>,
    /// 0 when the daemon sent none.
    pub updated_ms: f64,
    pub message_count: Option<i64>,
    pub accounts: Box<[Box<str>]>,
    pub roots: Box<[Box<str>]>,
    pub source_path: Option<Box<str>>,
    pub brand: Option<Box<str>>,
    /// What the live session continuing this chat needs (`needsInput`, `failed`, `unread`).
    pub attention: Option<Box<str>>,
    /// That session's latest reply, one line.
    pub preview: Option<Box<str>>,
    /// The chat whose agent started this one; a child is never listed on its own. None when empty.
    pub parent: Option<Box<str>>,
}

impl Chat {
    /// A chat with only the required fields (tests and hosts that build one by hand).
    pub fn new(key: &str, session_id: &str, harness: &str, updated_ms: f64) -> Self {
        Chat {
            key: key.into(),
            session_id: session_id.into(),
            harness: harness.into(),
            title: None,
            cwd: None,
            created_ms: None,
            updated_ms,
            message_count: None,
            accounts: Box::default(),
            roots: Box::default(),
            source_path: None,
            brand: None,
            attention: None,
            preview: None,
            parent: None,
        }
    }

    /// True when this chat is listed on its own (it has no parent chat).
    pub fn is_listed(&self) -> bool {
        self.parent.is_none()
    }

    pub(crate) fn from_wire(wire: WireChat) -> Option<Chat> {
        let key = wire.key.0.filter(|text| !text.is_empty())?;
        let session_id = wire.session_id.0.filter(|text| !text.is_empty())?;
        let harness = wire.harness.0.filter(|text| !text.is_empty())?;
        Some(Chat {
            key: key.into(),
            session_id: session_id.into(),
            harness: harness.into(),
            title: non_empty(wire.title.0),
            cwd: non_empty(wire.cwd.0),
            created_ms: wire.created_ms.0.or(wire.created_at.0),
            updated_ms: wire.updated_ms.0.or(wire.updated_at.0).unwrap_or(0.0),
            // NSNumber.intValue truncates; the index sends whole counts.
            #[allow(clippy::cast_possible_truncation)]
            message_count: wire.message_count.0.map(|count| count as i64),
            accounts: boxed(wire.accounts.0),
            roots: boxed(wire.roots.0),
            source_path: wire.source_path.0.map(Into::into),
            brand: wire.brand.0.map(Into::into),
            attention: wire.attention.0.map(Into::into),
            preview: wire.preview.0.map(Into::into),
            parent: non_empty(wire.parent.0),
        })
    }
}

pub(crate) fn non_empty(text: Option<String>) -> Option<Box<str>> {
    text.filter(|text| !text.is_empty()).map(Into::into)
}

fn boxed(texts: Vec<String>) -> Box<[Box<str>]> {
    texts.into_iter().map(Into::into).collect()
}

/// The daemon's `chat_value` object.
#[derive(serde::Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct WireChat {
    key: Text,
    session_id: Text,
    harness: Text,
    title: Text,
    cwd: Text,
    created_ms: Number,
    created_at: Number,
    updated_ms: Number,
    updated_at: Number,
    message_count: Number,
    accounts: Texts,
    roots: Texts,
    source_path: Text,
    brand: Text,
    attention: Text,
    preview: Text,
    parent: Text,
}

/// A string, or None for any other JSON value (which is skipped, not an error).
#[derive(Default, Debug)]
pub(crate) struct Text(pub(crate) Option<String>);

/// A number, or None for any other JSON value.
#[derive(Default, Debug)]
pub(crate) struct Number(pub(crate) Option<f64>);

/// A boolean, or None for any other JSON value.
#[derive(Default, Debug)]
pub(crate) struct Flag(pub(crate) Option<bool>);

/// An array of strings, or empty for any other JSON value (like Swift's `as? [String] ?? []`:
/// one non-string element empties the list).
#[derive(Default, Debug)]
pub(crate) struct Texts(pub(crate) Vec<String>);

/// What a lenient visitor keeps from a value.
trait Keep: Sized {
    fn string(_: String) -> Option<Self> {
        None
    }
    fn number(_: f64) -> Option<Self> {
        None
    }
    fn flag(_: bool) -> Option<Self> {
        None
    }
}

impl Keep for String {
    fn string(text: String) -> Option<Self> {
        Some(text)
    }
}

impl Keep for f64 {
    fn number(value: f64) -> Option<Self> {
        Some(value)
    }
}

impl Keep for bool {
    fn flag(value: bool) -> Option<Self> {
        Some(value)
    }
}

struct Lenient<T>(std::marker::PhantomData<T>);

impl<'de, T: Keep> Visitor<'de> for Lenient<T> {
    type Value = Option<T>;

    fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        formatter.write_str("any JSON value")
    }
    fn visit_str<E>(self, value: &str) -> Result<Self::Value, E> {
        Ok(T::string(value.to_owned()))
    }
    fn visit_string<E>(self, value: String) -> Result<Self::Value, E> {
        Ok(T::string(value))
    }
    fn visit_bool<E>(self, value: bool) -> Result<Self::Value, E> {
        Ok(T::flag(value))
    }
    #[allow(clippy::cast_precision_loss)]
    fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E> {
        Ok(T::number(value as f64))
    }
    #[allow(clippy::cast_precision_loss)]
    fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E> {
        Ok(T::number(value as f64))
    }
    fn visit_f64<E>(self, value: f64) -> Result<Self::Value, E> {
        Ok(T::number(value))
    }
    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(None)
    }
    fn visit_none<E>(self) -> Result<Self::Value, E> {
        Ok(None)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
        while seq.next_element::<IgnoredAny>()?.is_some() {}
        Ok(None)
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        while map.next_entry::<IgnoredAny, IgnoredAny>()?.is_some() {}
        Ok(None)
    }
}

impl<'de> Deserialize<'de> for Text {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(Lenient::<String>(std::marker::PhantomData)).map(Text)
    }
}

impl<'de> Deserialize<'de> for Number {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(Lenient::<f64>(std::marker::PhantomData)).map(Number)
    }
}

impl<'de> Deserialize<'de> for Flag {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(Lenient::<bool>(std::marker::PhantomData)).map(Flag)
    }
}

struct TextsVisitor;

impl<'de> Visitor<'de> for TextsVisitor {
    type Value = Vec<String>;

    fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        formatter.write_str("any JSON value")
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
        let mut texts = Vec::new();
        let mut all_strings = true;
        while let Some(Text(text)) = seq.next_element::<Text>()? {
            match text {
                Some(text) if all_strings => texts.push(text),
                _ => all_strings = false,
            }
        }
        if !all_strings {
            texts.clear();
        }
        Ok(texts)
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        while map.next_entry::<IgnoredAny, IgnoredAny>()?.is_some() {}
        Ok(Vec::new())
    }
    fn visit_str<E>(self, _: &str) -> Result<Self::Value, E> {
        Ok(Vec::new())
    }
    fn visit_bool<E>(self, _: bool) -> Result<Self::Value, E> {
        Ok(Vec::new())
    }
    fn visit_i64<E>(self, _: i64) -> Result<Self::Value, E> {
        Ok(Vec::new())
    }
    fn visit_u64<E>(self, _: u64) -> Result<Self::Value, E> {
        Ok(Vec::new())
    }
    fn visit_f64<E>(self, _: f64) -> Result<Self::Value, E> {
        Ok(Vec::new())
    }
    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(Vec::new())
    }
}

impl<'de> Deserialize<'de> for Texts {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(TextsVisitor).map(Texts)
    }
}
