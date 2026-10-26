//! A request line's head, parsed once before anything else reads the line
//! (p05-ipc-062). Chrome reads a Mojo message's header once
//! (`mojo/public/cpp/bindings/lib/message.cc`, `Message::header()`) and
//! routes on its name to the one receiver that decodes the payload
//! (`mojo/public/cpp/bindings/lib/multiplex_router.cc`, `Accept`); the
//! payload is decoded once, by that receiver. A line here gets the same
//! two steps: [`RequestHead::parse`] reads its routing members, borrowing
//! `cmd` and `operation` from the line, and skips every other member
//! without building it; then one handler decodes the line (the `Command`
//! parse, the v2 envelope, the page router or a feature route's entry).
//!
//! The head never refuses a member's type: a `cmd` that is not a string is
//! no command name, and the typed decode that follows answers the line as
//! it always did. Only a line that is not one JSON object has no head.

use std::borrow::Cow;
use std::fmt;
use std::sync::Arc;

use serde::Deserialize;
use serde::de::{self, Deserializer, IgnoredAny, MapAccess, Visitor};
use serde_json::Value;

use super::Command;
use super::request_spans::{RequestArrival, RequestMethod, RequestSpan, request_id_hash};
use crate::diagnostics::RequestStats;

/// The routing members of one request line.
#[derive(Debug, Default)]
pub(super) struct RequestHead<'a> {
    /// False when the line is not one JSON object: no route matches it and
    /// the `Command` parse answers it.
    parsed: bool,
    id: Option<Value>,
    cmd: Option<Cow<'a, str>>,
    /// A v2 envelope's `operation`, when it is a string.
    operation: Option<Cow<'a, str>>,
    /// Whether the line has a `protocol` member: a `cmux.protocol/2` line,
    /// answered by the resource router whatever its other members say.
    protocol: bool,
}

impl<'a> RequestHead<'a> {
    pub(super) fn parse(message: &'a str) -> Self {
        serde_json::from_str::<Self>(message).unwrap_or_default()
    }

    /// The line's `cmd`, when it is a string.
    pub(super) fn cmd(&self) -> Option<&str> {
        self.cmd.as_deref()
    }

    /// A v2 line's `operation`, when it is a string.
    pub(super) fn operation(&self) -> Option<&str> {
        self.operation.as_deref()
    }

    /// Whether the line is a `cmux.protocol/2` line (it has `protocol`).
    pub(super) fn is_resource(&self) -> bool {
        self.protocol
    }

    /// Whether the `Command` path answers this line (and opens its span):
    /// `cmd` names a `Command`, or the line has no head.
    pub(super) fn is_command(&self) -> bool {
        !self.parsed || self.command_method().is_some()
    }

    fn command_method(&self) -> Option<RequestMethod> {
        let (id, class) = Command::method_of_wire(self.cmd()?)?;
        Some(RequestMethod { id, class })
    }

    /// The method the line's span names: its `Command`, else the class of
    /// a feature route by its `cmd`.
    pub(super) fn method(&self) -> RequestMethod {
        self.command_method().unwrap_or_else(|| RequestMethod::routed(self.cmd()))
    }

    pub(super) fn open<'s>(
        &self,
        stats: &'s Arc<RequestStats>,
        arrival: RequestArrival,
    ) -> RequestSpan<'s> {
        RequestSpan::open_method(stats, self.method(), request_id_hash(self.id.as_ref()), arrival)
    }
}

impl<'de: 'a, 'a> Deserialize<'de> for RequestHead<'a> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_map(HeadVisitor)
    }
}

struct HeadVisitor;

impl<'de> Visitor<'de> for HeadVisitor {
    type Value = RequestHead<'de>;

    fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        formatter.write_str("a request object")
    }

    /// A repeated member keeps its last value, as the `Value` parse of the
    /// feature routes does.
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        let mut head = RequestHead { parsed: true, ..RequestHead::default() };
        while let Some(Text(key)) = map.next_key::<Text<'de>>()? {
            match key.as_ref() {
                "id" => head.id = map.next_value::<Option<Value>>()?,
                "cmd" => head.cmd = map.next_value::<Member<'de>>()?.text(),
                "operation" => head.operation = map.next_value::<Member<'de>>()?.text(),
                "protocol" => {
                    map.next_value::<IgnoredAny>()?;
                    head.protocol = true;
                }
                _ => {
                    map.next_value::<IgnoredAny>()?;
                }
            }
        }
        Ok(head)
    }
}

/// A string borrowed from the line when it has no escapes.
struct Text<'a>(Cow<'a, str>);

impl<'de: 'a, 'a> Deserialize<'de> for Text<'a> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct TextVisitor;
        impl<'de> Visitor<'de> for TextVisitor {
            type Value = Text<'de>;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("a string")
            }

            fn visit_borrowed_str<E: de::Error>(self, text: &'de str) -> Result<Self::Value, E> {
                Ok(Text(Cow::Borrowed(text)))
            }

            fn visit_str<E: de::Error>(self, text: &str) -> Result<Self::Value, E> {
                Ok(Text(Cow::Owned(text.to_owned())))
            }

            fn visit_string<E: de::Error>(self, text: String) -> Result<Self::Value, E> {
                Ok(Text(Cow::Owned(text)))
            }
        }
        deserializer.deserialize_str(TextVisitor)
    }
}

/// A routing member of any JSON type; only a string names anything.
enum Member<'a> {
    Text(Cow<'a, str>),
    Other,
}

impl<'a> Member<'a> {
    fn text(self) -> Option<Cow<'a, str>> {
        match self {
            Self::Text(text) => Some(text),
            Self::Other => None,
        }
    }
}

impl<'de: 'a, 'a> Deserialize<'de> for Member<'a> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct MemberVisitor;
        impl<'de> Visitor<'de> for MemberVisitor {
            type Value = Member<'de>;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("any JSON value")
            }

            fn visit_borrowed_str<E: de::Error>(self, text: &'de str) -> Result<Self::Value, E> {
                Ok(Member::Text(Cow::Borrowed(text)))
            }

            fn visit_str<E: de::Error>(self, text: &str) -> Result<Self::Value, E> {
                Ok(Member::Text(Cow::Owned(text.to_owned())))
            }

            fn visit_string<E: de::Error>(self, text: String) -> Result<Self::Value, E> {
                Ok(Member::Text(Cow::Owned(text)))
            }

            fn visit_bool<E: de::Error>(self, _: bool) -> Result<Self::Value, E> {
                Ok(Member::Other)
            }

            fn visit_i64<E: de::Error>(self, _: i64) -> Result<Self::Value, E> {
                Ok(Member::Other)
            }

            fn visit_u64<E: de::Error>(self, _: u64) -> Result<Self::Value, E> {
                Ok(Member::Other)
            }

            fn visit_f64<E: de::Error>(self, _: f64) -> Result<Self::Value, E> {
                Ok(Member::Other)
            }

            fn visit_unit<E: de::Error>(self) -> Result<Self::Value, E> {
                Ok(Member::Other)
            }

            fn visit_none<E: de::Error>(self) -> Result<Self::Value, E> {
                Ok(Member::Other)
            }

            fn visit_seq<A: de::SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
                while seq.next_element::<IgnoredAny>()?.is_some() {}
                Ok(Member::Other)
            }

            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                while map.next_entry::<IgnoredAny, IgnoredAny>()?.is_some() {}
                Ok(Member::Other)
            }
        }
        deserializer.deserialize_any(MemberVisitor)
    }
}

/// How many times one frame's line was parsed as JSON on its way to its
/// handler: the head, then the one decode that answers it. The frame
/// handler counts each parse it starts (a feature route's entry parses the
/// line once); `json_parses_per_request` in the p05-ipc plan is this count.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct JsonParses(u8);

impl JsonParses {
    pub(super) fn count(&mut self, parses: u8) {
        self.0 = self.0.saturating_add(parses);
    }

    pub(super) fn get(self) -> u8 {
        self.0
    }
}

#[cfg(test)]
#[path = "request_head_tests.rs"]
mod tests;
