//! The schema's method tables: what the framed transport knows about a method
//! without parsing its payload (p05-ipc design 3.3, spec/transports.md
//! "Framed IPC method attributes").
//!
//! Mojo scopes message ordinals per interface and dispatches on them through
//! generated code (mojo/public/tools/bindings/generators/cpp_templates/
//! interface_stub_declaration.tmpl and the `Accept` switch of
//! interface_definition.tmpl). cmux does the same with families: a wire id is
//! `family u8 << 8 | ordinal u8`, and each id space (v12 commands,
//! resource-operations-v2 operations, events) is a dense array of families,
//! each a dense array of ordinals. Looking up an id is two bounds-checked
//! indexes; looking up a name is one perfect-hash probe. Neither allocates.
//!
//! build.rs writes the tables from the schema files on every build; nothing
//! generated is committed. The daemon routes and prioritizes from its own
//! table (a header priority hint that differs is a bad message, design 3.2).

use crate::frame::PriorityHint;

/// A command or v2 operation id: `family << 8 | ordinal`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct MethodId(u16);

/// An event id: `family << 8 | ordinal`, family 0xC0-0xFE.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct EventId(u16);

macro_rules! wire_id {
    ($name:ident) => {
        impl $name {
            /// The id with wire value `raw`.
            pub const fn new(raw: u16) -> Self {
                Self(raw)
            }

            /// The wire value.
            pub const fn raw(self) -> u16 {
                self.0
            }

            /// The family byte.
            pub const fn family(self) -> u8 {
                self.0.to_be_bytes()[0]
            }

            /// The ordinal within the family.
            pub const fn ordinal(self) -> u8 {
                self.0.to_be_bytes()[1]
            }
        }
    };
}

wire_id!(MethodId);
wire_id!(EventId);

/// Family ranges of each id space (inclusive).
pub const V12_FAMILIES: (u8, u8) = (0x01, 0x5F);
pub const V2_FAMILIES: (u8, u8) = (0x60, 0xBF);
pub const EVENT_FAMILIES: (u8, u8) = (0xC0, 0xFE);

const V12_FAMILY_COUNT: usize = (V12_FAMILIES.1 - V12_FAMILIES.0) as usize + 1;
const V2_FAMILY_COUNT: usize = (V2_FAMILIES.1 - V2_FAMILIES.0) as usize + 1;
const EVENT_FAMILY_COUNT: usize = (EVENT_FAMILIES.1 - EVENT_FAMILIES.0) as usize + 1;

/// The schema `priority` is the frame header's priority hint: which outbound
/// queue and which pool workers serve the method. The daemon routes by its own
/// table; a header hint that differs is a bad message (design 3.2).
impl PriorityHint {
    /// The schema spelling.
    pub const fn schema_name(self) -> &'static str {
        match self {
            PriorityHint::Input => "input",
            PriorityHint::Control => "control",
            PriorityHint::Bulk => "bulk",
            PriorityHint::Background => "background",
        }
    }
}

/// The schema `ordering`: the connection or stream sequence, or a reviewed
/// read-only read that may run beside it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Ordering {
    Sequence,
    Independent,
}

impl Ordering {
    /// The schema spelling.
    pub const fn as_str(self) -> &'static str {
        match self {
            Ordering::Sequence => "sequence",
            Ordering::Independent => "independent",
        }
    }
}

/// The schema `durability`: what the reply waits for. Every framed command
/// states it; there is no default.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Durability {
    ReadOnly,
    Memory,
    ReplyBeforeJournal,
    ReplyAfterJournal,
}

impl Durability {
    /// The schema spelling.
    pub const fn as_str(self) -> &'static str {
        match self {
            Durability::ReadOnly => "read_only",
            Durability::Memory => "memory",
            Durability::ReplyBeforeJournal => "reply_before_journal",
            Durability::ReplyAfterJournal => "reply_after_journal",
        }
    }
}

/// The schema `payload`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Payload {
    Json,
    /// A fixed little-endian layout; the first payload byte is the version.
    Binary {
        layout_version: u8,
    },
}

/// The schema `coalesce`: a queued, unsent item with equal `key` fields is
/// replaced by a newer one; `additive` fields are summed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Coalesce {
    pub key: &'static [&'static str],
    pub additive: &'static [&'static str],
}

/// What the transport knows about a command or v2 operation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct MethodAttrs {
    pub id: MethodId,
    /// The wire name (`cmd` of a v12 line, `operation` of a v2 envelope).
    pub name: &'static str,
    pub priority: PriorityHint,
    pub ordering: Ordering,
    pub durability: Durability,
    pub payload: Payload,
    /// Addressed to one stream; runs on that stream's sequence.
    pub stream_scoped: bool,
    /// Why this control command may pass input queued on a stream of its
    /// target; `None` means it waits for that stream to drain.
    pub crosses_stream_ok: Option<&'static str>,
    /// Largest request payload; `None` is the frame cap.
    pub max_bytes: Option<u32>,
    pub coalesce: Option<Coalesce>,
    /// May ask the receiving scheduler to run it first (Mojo `[SupportsUrgent]`).
    pub urgent: bool,
}

/// What the transport knows about an event.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct EventAttrs {
    pub id: EventId,
    pub name: &'static str,
    pub priority: PriorityHint,
    pub coalesce: Option<Coalesce>,
}

/// One family: its entries indexed by ordinal (`None` is a free ordinal).
#[derive(Debug)]
pub struct FamilyTable<T: 'static> {
    pub id: u8,
    /// The schema's kebab-case family name.
    pub name: &'static str,
    pub entries: &'static [Option<T>],
}

impl<T> FamilyTable<T> {
    /// The entries that hold a method, in ordinal order.
    pub fn iter(&self) -> impl Iterator<Item = &T> {
        self.entries.iter().flatten()
    }
}

/// Every framed method and event of one schema build.
#[derive(Debug)]
pub struct MethodTables {
    v12: [Option<&'static FamilyTable<MethodAttrs>>; V12_FAMILY_COUNT],
    v2: [Option<&'static FamilyTable<MethodAttrs>>; V2_FAMILY_COUNT],
    events: [Option<&'static FamilyTable<EventAttrs>>; EVENT_FAMILY_COUNT],
    v12_names: phf::Map<&'static str, MethodId>,
    v2_names: phf::Map<&'static str, MethodId>,
    event_names: phf::Map<&'static str, EventId>,
}

include!(concat!(env!("OUT_DIR"), "/method_tables.rs"));

#[cfg(test)]
include!(concat!(env!("OUT_DIR"), "/method_tables_fixture.rs"));

fn entry<T>(
    families: &[Option<&'static FamilyTable<T>>],
    (first, last): (u8, u8),
    family: u8,
    ordinal: u8,
) -> Option<&'static T> {
    if !(first..=last).contains(&family) {
        return None;
    }
    let table = (*families.get(usize::from(family - first))?)?;
    table.entries.get(usize::from(ordinal))?.as_ref()
}

impl MethodTables {
    /// The tables of the schema this binary was built from.
    pub fn schema() -> &'static MethodTables {
        &TABLES
    }

    /// The command or v2 operation with `id`, by its family range.
    pub fn method(&self, id: MethodId) -> Option<&'static MethodAttrs> {
        self.v12(id).or_else(|| self.v2(id))
    }

    /// The v12 command with `id`.
    pub fn v12(&self, id: MethodId) -> Option<&'static MethodAttrs> {
        entry(&self.v12, V12_FAMILIES, id.family(), id.ordinal())
    }

    /// The resource-operations-v2 operation with `id`.
    pub fn v2(&self, id: MethodId) -> Option<&'static MethodAttrs> {
        entry(&self.v2, V2_FAMILIES, id.family(), id.ordinal())
    }

    /// The event with `id`.
    pub fn event(&self, id: EventId) -> Option<&'static EventAttrs> {
        entry(&self.events, EVENT_FAMILIES, id.family(), id.ordinal())
    }

    /// The id of the v12 command named `name` (a line's `cmd`).
    pub fn v12_id(&self, name: &str) -> Option<MethodId> {
        self.v12_names.get(name).copied()
    }

    /// The id of the v2 operation named `name` (an envelope's `operation`).
    pub fn v2_id(&self, name: &str) -> Option<MethodId> {
        self.v2_names.get(name).copied()
    }

    /// The id of the event named `name`.
    pub fn event_id(&self, name: &str) -> Option<EventId> {
        self.event_names.get(name).copied()
    }

    /// The v12 families present, in id order.
    pub fn v12_families(&self) -> impl Iterator<Item = &'static FamilyTable<MethodAttrs>> + '_ {
        self.v12.iter().flatten().copied()
    }

    /// The v2 families present, in id order.
    pub fn v2_families(&self) -> impl Iterator<Item = &'static FamilyTable<MethodAttrs>> + '_ {
        self.v2.iter().flatten().copied()
    }

    /// The event families present, in id order.
    pub fn event_families(&self) -> impl Iterator<Item = &'static FamilyTable<EventAttrs>> + '_ {
        self.events.iter().flatten().copied()
    }
}
