//! Typed replies of the sidebar mirror (bead cx-x5jpp): fixed-size C structs
//! plus one interned UTF-8 string table, so the app reads the rows, the
//! acceptance table and a call's status with no JSON decode on its main
//! thread. Each reply lives in the mirror and stays valid until the next
//! typed call on the same mirror (or its free); the caller copies what it
//! keeps.

use cmux_layout_reducer::sidebar_doc::{accept::Acceptance, view::Row};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};

/// No string: an absent optional field.
pub const NONE: u32 = u32::MAX;

pub const ROW_DIMMED: u8 = 1;
pub const ROW_COLLAPSED: u8 = 2;
pub const ROW_ARCHIVED: u8 = 4;
pub const ACCEPT_BEFORE: u8 = 1;
pub const ACCEPT_INTO: u8 = 2;
pub const ACCEPT_AFTER: u8 = 4;

/// The strings of one reply: string `i` is `bytes[offsets[i]..offsets[i + 1]]`
/// (`offsets` has `count + 1` entries).
#[repr(C)]
pub struct Strings {
    pub bytes: *const u8,
    pub offsets: *const u32,
    pub count: u32,
}

/// One row of `view`; string fields index the reply's table.
#[repr(C)]
pub struct CRow {
    pub key: u32,
    pub kind: u32,
    pub section: u32,
    pub parent: u32,
    pub item: u32,
    pub ref_session: u32,
    pub ref_workspace: u32,
    pub depth: u8,
    pub flags: u8,
    pub reserved: u16,
}

/// `view`'s reply. `ok` is 0 when the request could not be read (no rows).
#[repr(C)]
pub struct CRows {
    pub ok: u8,
    pub rows: *const CRow,
    pub row_count: u32,
    pub strings: Strings,
}

/// One entry of the acceptance table, by row key.
#[repr(C)]
pub struct CAcceptance {
    pub key: u32,
    pub refusal: u32,
    pub flags: u8,
    pub reserved: [u8; 3],
}

/// `drag_begin`'s reply. `ok` is 0 when the request could not be read.
#[repr(C)]
pub struct CAcceptanceTable {
    pub ok: u8,
    pub entries: *const CAcceptance,
    pub count: u32,
    pub strings: Strings,
}

/// The status of `load`, `apply_batch` and `apply_intent`: the fields the
/// JSON reply has (`ok`, `stale`, `refetch`, `refusal` or `error`,
/// `revision`), and for an intent its stamped ops as a JSON array (bytes the
/// app sends on to the daemon, never decodes).
#[repr(C)]
pub struct CReply {
    pub ok: u8,
    pub stale: u8,
    pub refetch: u8,
    pub has_revision: u8,
    pub revision: u64,
    /// UTF-8, not NUL-terminated; null with length 0 for none.
    pub refusal: *const u8,
    pub refusal_len: usize,
    pub ops: *const u8,
    pub ops_len: usize,
}

struct Table {
    bytes: Vec<u8>,
    offsets: Vec<u32>,
    index: HashMap<String, u32>,
}

impl Default for Table {
    fn default() -> Self {
        Table { bytes: Vec::new(), offsets: vec![0], index: HashMap::new() }
    }
}

impl Table {
    fn intern(&mut self, text: &str) -> u32 {
        if let Some(&id) = self.index.get(text) {
            return id;
        }
        let id = (self.offsets.len() - 1) as u32;
        self.bytes.extend_from_slice(text.as_bytes());
        self.offsets.push(self.bytes.len() as u32);
        self.index.insert(text.to_string(), id);
        id
    }

    fn optional(&mut self, text: Option<&str>) -> u32 {
        text.map_or(NONE, |text| self.intern(text))
    }

    fn c(&self) -> Strings {
        Strings {
            bytes: self.bytes.as_ptr(),
            offsets: self.offsets.as_ptr(),
            count: (self.offsets.len() - 1) as u32,
        }
    }
}

/// The buffers behind the mirror's last typed replies.
#[derive(Default)]
pub struct Out {
    rows_table: Table,
    rows: Vec<CRow>,
    rows_reply: Option<CRows>,
    accept_table: Table,
    entries: Vec<CAcceptance>,
    accept_reply: Option<CAcceptanceTable>,
    refusal: String,
    ops: Vec<u8>,
    reply: Option<CReply>,
}

impl Out {
    pub fn rows(&mut self, rows: Option<&[Row]>) -> *const CRows {
        let mut table = Table::default();
        let mut out = Vec::with_capacity(rows.map_or(0, <[Row]>::len));
        for row in rows.unwrap_or_default() {
            let reference = row.reference.as_ref();
            out.push(CRow {
                key: table.intern(&row.key),
                kind: table.intern(&row.kind),
                section: table.intern(&row.section),
                parent: table.optional(row.parent.as_deref()),
                item: table.optional(row.item.as_deref()),
                ref_session: table.optional(reference.map(|r| r.session_id.as_str())),
                ref_workspace: table.optional(reference.map(|r| r.workspace_id.as_str())),
                depth: row.depth,
                flags: if row.dimmed { ROW_DIMMED } else { 0 }
                    | if row.collapsed { ROW_COLLAPSED } else { 0 }
                    | if row.archived { ROW_ARCHIVED } else { 0 },
                reserved: 0,
            });
        }
        self.rows_table = table;
        self.rows = out;
        self.rows_reply = Some(CRows {
            ok: u8::from(rows.is_some()),
            rows: self.rows.as_ptr(),
            row_count: self.rows.len() as u32,
            strings: self.rows_table.c(),
        });
        self.rows_reply.as_ref().map_or(std::ptr::null(), std::ptr::from_ref)
    }

    pub fn acceptance(
        &mut self,
        accepted: Option<&BTreeMap<String, Acceptance>>,
    ) -> *const CAcceptanceTable {
        let mut table = Table::default();
        let mut out = Vec::with_capacity(accepted.map_or(0, BTreeMap::len));
        for (key, acceptance) in accepted.into_iter().flatten() {
            out.push(CAcceptance {
                key: table.intern(key),
                refusal: table.optional(acceptance.refusal.as_deref()),
                flags: if acceptance.before { ACCEPT_BEFORE } else { 0 }
                    | if acceptance.into { ACCEPT_INTO } else { 0 }
                    | if acceptance.after { ACCEPT_AFTER } else { 0 },
                reserved: [0; 3],
            });
        }
        self.accept_table = table;
        self.entries = out;
        self.accept_reply = Some(CAcceptanceTable {
            ok: u8::from(accepted.is_some()),
            entries: self.entries.as_ptr(),
            count: self.entries.len() as u32,
            strings: self.accept_table.c(),
        });
        self.accept_reply.as_ref().map_or(std::ptr::null(), std::ptr::from_ref)
    }

    /// The typed status of a JSON reply (the same fields the JSON entries
    /// answer, so both entry kinds agree).
    pub fn reply(&mut self, value: &Value) -> *const CReply {
        let flag = |name: &str| u8::from(value[name] == true);
        let revision = value["revision"]
            .as_str()
            .and_then(|text| text.parse::<u64>().ok())
            .or_else(|| value["revision"].as_u64());
        self.refusal = value["refusal"]
            .as_str()
            .map(str::to_string)
            .or_else(|| value.get("error").map(|_| "error".to_string()))
            .unwrap_or_default();
        self.ops = value
            .get("ops")
            .filter(|ops| ops.is_array())
            .and_then(|ops| serde_json::to_vec(ops).ok())
            .unwrap_or_default();
        let bytes = |data: &[u8]| if data.is_empty() { std::ptr::null() } else { data.as_ptr() };
        self.reply = Some(CReply {
            ok: flag("ok"),
            stale: flag("stale"),
            refetch: flag("refetch"),
            has_revision: u8::from(revision.is_some()),
            revision: revision.unwrap_or_default(),
            refusal: bytes(self.refusal.as_bytes()),
            refusal_len: self.refusal.len(),
            ops: bytes(&self.ops),
            ops_len: self.ops.len(),
        });
        self.reply.as_ref().map_or(std::ptr::null(), std::ptr::from_ref)
    }
}
