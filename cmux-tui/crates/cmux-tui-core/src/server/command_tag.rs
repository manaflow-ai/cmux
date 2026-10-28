//! `Request`'s `Command`, chosen by its `cmd` name only (p05-ipc-182).
//!
//! `Request` flattens `Command`, so serde buffers the line's members and
//! reads the `cmd` tag from that buffer, where a variant identifier also
//! accepts an integer (the variant's index). `{"cmd":163}` would then run
//! the 163rd command while the head (`RequestHead`, which reads only a
//! string `cmd`), its span and the frame checks name none. The wire names a
//! command by its name, so here the tag is read as a string: any other type
//! is refused as a bad request, as it is when `Command` is parsed directly.

use std::fmt;

use serde::Deserialize;
use serde::de::{DeserializeSeed, Deserializer, MapAccess, Visitor};

use super::Command;

/// `#[serde(flatten, deserialize_with)]` of `Request::cmd`.
pub(super) fn command_by_name<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> Result<Command, D::Error> {
    Command::deserialize(NamedTag(deserializer))
}

/// The flattened members, whose values read an identifier only from a
/// string. An internally tagged enum reads its content with
/// `deserialize_any` and `visit_map`, the only path forwarded here.
struct NamedTag<D>(D);

impl<'de, D: Deserializer<'de>> Deserializer<'de> for NamedTag<D> {
    type Error = D::Error;

    fn deserialize_any<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, D::Error> {
        self.0.deserialize_any(NamedMembers(visitor))
    }

    serde::forward_to_deserialize_any! {
        bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 char str string bytes byte_buf
        option unit unit_struct newtype_struct seq tuple tuple_struct map struct enum
        identifier ignored_any
    }
}

struct NamedMembers<V>(V);

impl<'de, V: Visitor<'de>> Visitor<'de> for NamedMembers<V> {
    type Value = V::Value;

    fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        self.0.expecting(formatter)
    }

    fn visit_map<A: MapAccess<'de>>(self, map: A) -> Result<Self::Value, A::Error> {
        self.0.visit_map(NamedMap(map))
    }
}

struct NamedMap<A>(A);

impl<'de, A: MapAccess<'de>> MapAccess<'de> for NamedMap<A> {
    type Error = A::Error;

    fn next_key_seed<K: DeserializeSeed<'de>>(
        &mut self,
        seed: K,
    ) -> Result<Option<K::Value>, A::Error> {
        self.0.next_key_seed(seed)
    }

    fn next_value_seed<S: DeserializeSeed<'de>>(&mut self, seed: S) -> Result<S::Value, A::Error> {
        self.0.next_value_seed(NamedValue(seed))
    }

    fn size_hint(&self) -> Option<usize> {
        self.0.size_hint()
    }
}

struct NamedValue<S>(S);

impl<'de, S: DeserializeSeed<'de>> DeserializeSeed<'de> for NamedValue<S> {
    type Value = S::Value;

    fn deserialize<D: Deserializer<'de>>(self, deserializer: D) -> Result<S::Value, D::Error> {
        self.0.deserialize(StringIdentifier(deserializer))
    }
}

/// A member's value: an identifier (the tag) is read as a string; anything
/// else as it is written.
struct StringIdentifier<D>(D);

impl<'de, D: Deserializer<'de>> Deserializer<'de> for StringIdentifier<D> {
    type Error = D::Error;

    fn deserialize_any<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, D::Error> {
        self.0.deserialize_any(visitor)
    }

    fn deserialize_identifier<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, D::Error> {
        self.0.deserialize_str(visitor)
    }

    serde::forward_to_deserialize_any! {
        bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 char str string bytes byte_buf
        option unit unit_struct newtype_struct seq tuple tuple_struct map struct enum
        ignored_any
    }
}
