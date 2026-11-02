//! The app's bookmark mirror (layer-ownership.md V-11): per browser
//! profile, the confirmed tree (the last `list-bookmarks` listing) and the
//! shown tree (confirmed plus the pending edits, by the daemon's own rules),
//! both kept here so an edit costs only what it changes. The app keeps a
//! read model fed by the deltas and holds no bookmark rules.
//!
//! Calls (JSON in, JSON out; `cmux_bookmark_mirror_call` in the app FFI):
//!
//! - `load` `{browser_profile_id, bookmarks:[Bookmark]}` (a `list-bookmarks`
//!   listing, fetched after the replies the app settled) ->
//!   `{tree:[Bookmark], dropped:[key]}`. The listing becomes the confirmed
//!   tree; settled edits and pending imports leave; the other pending edits
//!   are replayed on it in order, and one that no longer applies leaves.
//!   O(the profile): the echo path, never the edit path.
//! - `apply` `{browser_profile_id, key, op, now_ms}` -> `{result, changed,
//!   delta}` or `{error_code, reason, message}`. The edit goes on the shown
//!   tree; a changing one stays pending under `key` until settled. `delta`
//!   is a ``Delta``. O(the changed items).
//! - `settle` `{browser_profile_id, key}`: the edit's command replied; it
//!   leaves at the next `load`.
//! - `reject` `{browser_profile_id, key}` -> `{tree}`: the command failed;
//!   the edit leaves and the shown tree is rebuilt.
//! - `view` `{browser_profile_id}` -> `{tree}`: the shown tree in listing
//!   order (a cold read).
//! - `forget` `{browser_profile_id}`: the profile was deleted.
//!
//! A malformed call answers `{"error": "..."}`.
//!
//! A pending import is never replayed: its ids are local (the daemon mints
//! its own), so replaying it on a listing that holds the daemon's copy
//! would show it twice. It leaves at the next `load`; if that listing
//! predates the import, the import shows again with its own echo.

use std::collections::HashMap;

use serde::Deserialize;
use serde_json::{Value, json};

use crate::preview::IdMint;
use crate::{Bookmark, BookmarkError, BookmarkOp, Tree};

/// One app process's bookmark trees (one handle per app, used from one
/// thread at a time).
#[derive(Debug, Default)]
pub struct Mirror {
    profiles: HashMap<String, Profile>,
    ids: IdMint,
}

#[derive(Debug, Default)]
struct Profile {
    confirmed: Tree,
    shown: Tree,
    pending: Vec<Pending>,
}

#[derive(Debug)]
struct Pending {
    key: String,
    op: BookmarkOp,
    settled: bool,
}

#[derive(Deserialize)]
struct Load {
    browser_profile_id: String,
    #[serde(default)]
    bookmarks: Vec<Bookmark>,
}

#[derive(Deserialize)]
struct Apply {
    browser_profile_id: String,
    key: String,
    op: BookmarkOp,
    now_ms: u64,
}

#[derive(Deserialize)]
struct Keyed {
    browser_profile_id: String,
    key: String,
}

#[derive(Deserialize)]
struct ProfileOnly {
    browser_profile_id: String,
}

fn refusal(error: &BookmarkError) -> Value {
    json!({"error_code": error.code(), "reason": error.reason(), "message": error.message()})
}

fn parse<'a, T: Deserialize<'a>>(input: &'a [u8]) -> Result<T, Value> {
    serde_json::from_slice(input).map_err(|error| json!({"error": error.to_string()}))
}

impl Mirror {
    /// A mirror whose local ids (imports) come from `seed`.
    pub fn new(seed: u64) -> Self {
        Self { profiles: HashMap::new(), ids: IdMint::new(seed) }
    }

    /// Runs one call by name (see the module doc).
    pub fn call(&mut self, name: &str, input: &[u8]) -> Value {
        let reply = match name {
            "load" => parse(input).map(|call| self.load(call)),
            "apply" => parse(input).map(|call| self.apply(call)),
            "settle" => parse(input).map(|call| self.settle(call)),
            "reject" => parse(input).map(|call| self.reject(call)),
            "view" => parse::<ProfileOnly>(input).map(|call| self.view(&call.browser_profile_id)),
            "forget" => parse::<ProfileOnly>(input).map(|call| {
                self.profiles.remove(&call.browser_profile_id);
                json!({"ok": true})
            }),
            _ => Err(json!({"error": format!("unknown call {name}")})),
        };
        reply.unwrap_or_else(|error| error)
    }

    fn profile(&mut self, id: &str) -> &mut Profile {
        self.profiles.entry(id.to_string()).or_insert_with(|| Profile {
            confirmed: Tree::new(id),
            shown: Tree::new(id),
            pending: Vec::new(),
        })
    }

    fn load(&mut self, call: Load) -> Value {
        let id = call.browser_profile_id;
        let confirmed = Tree::from_listing(id.clone(), call.bookmarks);
        let mut ids = std::mem::take(&mut self.ids);
        let profile = self.profile(&id);
        let mut dropped = Vec::new();
        let pending = std::mem::take(&mut profile.pending);
        profile.confirmed = confirmed;
        profile.shown = profile.confirmed.clone();
        for entry in pending {
            if entry.settled || matches!(entry.op, BookmarkOp::Import(_)) {
                dropped.push(entry.key);
                continue;
            }
            match profile.shown.apply(entry.op.clone(), 0, &mut || ids.next_id()) {
                Ok(_) => profile.pending.push(entry),
                Err(_) => dropped.push(entry.key),
            }
        }
        let tree = profile.shown.listing();
        self.ids = ids;
        json!({"tree": tree, "dropped": dropped})
    }

    fn apply(&mut self, call: Apply) -> Value {
        let mut ids = std::mem::take(&mut self.ids);
        let profile = self.profile(&call.browser_profile_id);
        let reply = if profile.pending.iter().any(|entry| entry.key == call.key) {
            refusal(&BookmarkError::invalid(format!("edit {} is already pending", call.key)))
        } else {
            let op = call.op.clone();
            match profile.shown.apply_with_delta(call.op, call.now_ms, &mut || ids.next_id()) {
                Ok((applied, delta)) => {
                    if applied.changed {
                        profile.pending.push(Pending { key: call.key, op, settled: false });
                    }
                    json!({"result": applied.result, "changed": applied.changed, "delta": delta})
                }
                Err(error) => refusal(&error),
            }
        };
        self.ids = ids;
        reply
    }

    fn settle(&mut self, call: Keyed) -> Value {
        let profile = self.profile(&call.browser_profile_id);
        let found = profile.pending.iter_mut().find(|entry| entry.key == call.key);
        let known = found.is_some();
        if let Some(entry) = found {
            entry.settled = true;
        }
        json!({"ok": known})
    }

    fn reject(&mut self, call: Keyed) -> Value {
        let mut ids = std::mem::take(&mut self.ids);
        let profile = self.profile(&call.browser_profile_id);
        profile.pending.retain(|entry| entry.key != call.key);
        profile.shown = profile.confirmed.clone();
        let mut kept = Vec::with_capacity(profile.pending.len());
        for entry in std::mem::take(&mut profile.pending) {
            if profile.shown.apply(entry.op.clone(), 0, &mut || ids.next_id()).is_ok() {
                kept.push(entry);
            }
        }
        profile.pending = kept;
        let tree = profile.shown.listing();
        self.ids = ids;
        json!({"tree": tree})
    }

    fn view(&mut self, id: &str) -> Value {
        json!({"tree": self.profile(id).shown.listing()})
    }
}
