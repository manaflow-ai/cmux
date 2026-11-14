//! The allow-list of the slow request log: the only keys of a request line a record may hold,
//! and the grammar each value must pass. A key that is not listed here is skipped unread; a
//! listed key whose value does not pass its grammar (a name, a path, typed text) is dropped.

use std::fmt::Write as _;

use serde::de::{DeserializeSeed, Deserializer, IgnoredAny, MapAccess, SeqAccess, Visitor};

const LABEL_BYTES: usize = 48;
/// The id keys a record may hold, at the top level of a line or in its `params`.
pub(super) const ID_KEYS: [&str; 7] =
    ["workspace", "screen", "pane", "tab", "surface", "terminal", "browser"];
const TERMINAL_KEY: usize = 5;
/// The client names and kinds a record may hold: fixed words of cmux's own clients. A client sets
/// its name and kind itself (`set-client-info`), and a TUI sends the computer's hostname as its
/// name: any text that is not one of these words is not written.
const CLIENT_WORDS: [&str; 15] = [
    "agent",
    "cmux-next",
    "cmux-next-chief-profile-relay",
    "cmux-next-home",
    "cmux-next-mobile-compat",
    "cmux-next-page-relay",
    "frontend",
    "ios",
    "mac",
    "machine",
    "mcp",
    "script",
    "tui",
    "web",
    "web-client",
];

/// A short ASCII word that passed one of the grammars below: the only text a record holds.
#[derive(Clone, Copy)]
pub(crate) struct Label {
    len: u8,
    bytes: [u8; LABEL_BYTES],
}

impl Label {
    fn copied(text: &[u8]) -> Self {
        let len = text.len().min(LABEL_BYTES);
        let mut bytes = [0; LABEL_BYTES];
        // `zip` stops at the shorter side: a longer text is cut at `LABEL_BYTES`.
        for (slot, byte) in bytes.iter_mut().zip(text) {
            *slot = *byte;
        }
        Self { len: len as u8, bytes }
    }

    pub(super) fn as_str(&self) -> &str {
        let text = self.bytes.get(..usize::from(self.len)).unwrap_or_default();
        std::str::from_utf8(text).unwrap_or_default()
    }

    /// A command name, an operation name or an error code: `[a-z0-9._-]{1,48}`.
    pub(super) fn token(text: &str) -> Option<Self> {
        let bytes = text.as_bytes();
        let fits = !bytes.is_empty()
            && bytes.len() <= LABEL_BYTES
            && bytes
                .iter()
                .all(|byte| matches!(byte, b'a'..=b'z' | b'0'..=b'9' | b'.' | b'_' | b'-'));
        fits.then(|| Self::copied(bytes))
    }

    /// An object id in a string: a public id (`<prefix>_<32 hex>`), 32 hex digits, a UUID, or the
    /// word `current`. A name (which a selector may also be) is not an id, also when it is all
    /// digits: a numeric id is a JSON number (`number`).
    fn id(text: &str) -> Option<Self> {
        let bytes = text.as_bytes();
        let hex = |part: &[u8]| part.iter().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'));
        let fits = match bytes.len() {
            0 => false,
            length if length > LABEL_BYTES => false,
            _ if text == "current" => true,
            32 if hex(bytes) => true,
            36 if bytes.iter().enumerate().all(|(index, byte)| match index {
                8 | 13 | 18 | 23 => *byte == b'-',
                _ => matches!(byte, b'0'..=b'9' | b'a'..=b'f'),
            }) =>
            {
                true
            }
            _ => text.rsplit_once('_').is_some_and(|(prefix, payload)| {
                !prefix.is_empty()
                    && prefix.bytes().all(|byte| byte.is_ascii_lowercase() || byte == b'_')
                    && payload.len() == 32
                    && hex(payload.as_bytes())
            }),
        };
        fits.then(|| Self::copied(bytes))
    }

    fn number(value: u64) -> Self {
        let mut text = String::with_capacity(20);
        let _ = write!(text, "{value}");
        Self::copied(text.as_bytes())
    }

    /// A client's own name or kind (`set-client-info`), only when it is one of `CLIENT_WORDS`.
    pub(crate) fn client(text: &str) -> Option<Self> {
        CLIENT_WORDS.contains(&text).then(|| Self::copied(text.as_bytes()))
    }

    /// The 16 hex digits that end a session folder's name (`<name>-<hash>`). The name before them
    /// is the person's own text when the daemon was started with `--session NAME`: not written.
    pub(crate) fn session_hash(folder: &str) -> Option<Self> {
        let (_, hash) = folder.rsplit_once('-')?;
        let fits = hash.len() == 16 && hash.bytes().all(|byte| byte.is_ascii_hexdigit());
        fits.then(|| Self::copied(hash.as_bytes()))
    }

    /// A thread's name up to its first `:` (an app host thread has an app id after it): at most
    /// 48 bytes, every byte outside `[A-Za-z0-9_.-]` replaced by `_`.
    pub(crate) fn thread(name: &str) -> Option<Self> {
        Self::word(name.split(':').next().unwrap_or_default())
    }

    fn word(text: &str) -> Option<Self> {
        let mut label = Self::copied(text.as_bytes());
        let len = usize::from(label.len);
        for byte in label.bytes.iter_mut().take(len) {
            if !matches!(byte, b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'.' | b'_' | b'-') {
                *byte = b'_';
            }
        }
        (label.len > 0).then_some(label)
    }

    /// A decimal number that JSON can hold as written.
    pub(super) fn is_number(&self) -> bool {
        let text = self.as_str();
        self.len <= 15
            && text.bytes().all(|byte| byte.is_ascii_digit())
            && (self.len == 1 || !text.starts_with('0'))
    }
}

/// What a record keeps of a request line.
#[derive(Clone, Copy, Default)]
pub(super) struct Allowed {
    /// The line's `cmd`, when it has exactly one that passes the name grammar.
    pub(super) cmd: Option<Label>,
    cmds: u8,
    pub(super) ids: [Option<Label>; ID_KEYS.len()],
}

enum Key {
    Name,
    Params,
    Id(usize),
    Other,
}

impl<'de> serde::Deserialize<'de> for Key {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct KeyVisitor;
        impl Visitor<'_> for KeyVisitor {
            type Value = Key;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("an object key")
            }

            fn visit_str<E>(self, key: &str) -> Result<Key, E> {
                Ok(match key {
                    "cmd" => Key::Name,
                    "params" => Key::Params,
                    "terminal_id" => Key::Id(TERMINAL_KEY),
                    other => ID_KEYS.iter().position(|id| *id == other).map_or(Key::Other, Key::Id),
                })
            }
        }
        deserializer.deserialize_str(KeyVisitor)
    }
}

/// One allow-listed value: a word of its grammar, or nothing for every other value.
#[derive(Clone, Copy)]
enum Slot {
    Name,
    Id,
}

impl<'de> DeserializeSeed<'de> for Slot {
    type Value = Option<Label>;

    fn deserialize<D: Deserializer<'de>>(self, deserializer: D) -> Result<Self::Value, D::Error> {
        deserializer.deserialize_any(self)
    }
}

impl<'de> Visitor<'de> for Slot {
    type Value = Option<Label>;

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("any value")
    }

    fn visit_str<E>(self, text: &str) -> Result<Self::Value, E> {
        Ok(match self {
            Self::Name => Label::token(text),
            Self::Id => Label::id(text),
        })
    }

    fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E> {
        Ok(matches!(self, Self::Id).then(|| Label::number(value)))
    }

    fn visit_i64<E>(self, _: i64) -> Result<Self::Value, E> {
        Ok(None)
    }

    fn visit_f64<E>(self, _: f64) -> Result<Self::Value, E> {
        Ok(None)
    }

    fn visit_bool<E>(self, _: bool) -> Result<Self::Value, E> {
        Ok(None)
    }

    fn visit_unit<E>(self) -> Result<Self::Value, E> {
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

/// The allow-listed keys of one object: the line (`top`) or its `params`.
struct Fields<'a> {
    out: &'a mut Allowed,
    top: bool,
}

impl<'de> DeserializeSeed<'de> for Fields<'_> {
    type Value = ();

    fn deserialize<D: Deserializer<'de>>(self, deserializer: D) -> Result<(), D::Error> {
        deserializer.deserialize_any(self)
    }
}

impl<'de> Visitor<'de> for Fields<'_> {
    type Value = ();

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("any value")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<(), A::Error> {
        let Fields { out, top } = self;
        while let Some(key) = map.next_key::<Key>()? {
            match key {
                Key::Name if top => {
                    // Two `cmd` keys: the daemon's decoder and this one could read different ones.
                    let cmd = map.next_value_seed(Slot::Name)?;
                    out.cmd = if out.cmds == 0 { cmd } else { None };
                    out.cmds = out.cmds.saturating_add(1);
                }
                Key::Params if top => map.next_value_seed(Fields { out: &mut *out, top: false })?,
                Key::Id(index) => {
                    if let Some(id) = map.next_value_seed(Slot::Id)?
                        && let Some(slot) = out.ids.get_mut(index)
                    {
                        *slot = Some(id);
                    }
                }
                _ => {
                    map.next_value::<IgnoredAny>()?;
                }
            }
        }
        Ok(())
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<(), A::Error> {
        while seq.next_element::<IgnoredAny>()?.is_some() {}
        Ok(())
    }

    fn visit_str<E>(self, _: &str) -> Result<(), E> {
        Ok(())
    }

    fn visit_u64<E>(self, _: u64) -> Result<(), E> {
        Ok(())
    }

    fn visit_i64<E>(self, _: i64) -> Result<(), E> {
        Ok(())
    }

    fn visit_f64<E>(self, _: f64) -> Result<(), E> {
        Ok(())
    }

    fn visit_bool<E>(self, _: bool) -> Result<(), E> {
        Ok(())
    }

    fn visit_unit<E>(self) -> Result<(), E> {
        Ok(())
    }
}

/// The name and ids of `line`; nothing else of it is read into the record.
pub(super) fn allowed_fields(line: &str) -> Allowed {
    let mut out = Allowed::default();
    let mut deserializer = serde_json::Deserializer::from_str(line);
    let _ = Fields { out: &mut out, top: true }.deserialize(&mut deserializer);
    out
}
