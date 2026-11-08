//! The app's optimistic bookmark view (for the app FFI op `bookmarks_apply`,
//! layer-ownership.md V-11): the confirmed tree (the
//! last `list-bookmarks` listing) with the pending ops applied in order by
//! the daemon's own rules. A pending op the visible tree refuses (its
//! target is gone, or it is already applied and now conflicts) changes
//! nothing and reports its refusal, as the daemon would.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{Bookmark, BookmarkOp, Reason, Tree};

/// `{browser_profile_id, tree: [Bookmark], ops: [BookmarkOp], now_ms, seed?}`.
/// `ops` use the daemon's op JSON (`{"op": "create", ...}`, the replay
/// fingerprint shape). `seed` makes the ids of created nodes that name none
/// (imports); the daemon mints its own, which replace them on its echo.
#[derive(Debug, Clone, Deserialize)]
pub struct Request {
    pub browser_profile_id: String,
    #[serde(default)]
    pub tree: Vec<Bookmark>,
    #[serde(default)]
    pub ops: Vec<BookmarkOp>,
    pub now_ms: u64,
    #[serde(default)]
    pub seed: Option<u64>,
}

/// The visible tree in listing order, and one result per op.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Response {
    pub tree: Vec<Bookmark>,
    pub results: Vec<OpResult>,
}

/// `{result, changed}` (the daemon's wire result) or `{error_code, reason,
/// message}` (`reason` names the rule, for the app's localized text).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(untagged)]
pub enum OpResult {
    Applied { result: Value, changed: bool },
    Refused { error_code: &'static str, reason: Reason, message: String },
}

pub fn respond(request: Request) -> Response {
    let mut tree = Tree::from_listing(request.browser_profile_id, request.tree);
    let mut ids = IdMint::new(request.seed.unwrap_or(request.now_ms));
    let mut mint = || ids.next_id();
    let results = request
        .ops
        .into_iter()
        .map(|op| match tree.apply(op, request.now_ms, &mut mint) {
            Ok(applied) => OpResult::Applied { result: applied.result, changed: applied.changed },
            Err(error) => OpResult::Refused {
                error_code: error.code(),
                reason: error.reason(),
                message: error.message().to_string(),
            },
        })
        .collect();
    Response { tree: tree.listing(), results }
}

/// Well-formed bookmark ids from a seed (splitmix64), so a preview is
/// reproducible and needs no random source.
#[derive(Debug, Clone)]
pub struct IdMint {
    state: u64,
}

impl IdMint {
    pub fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    /// `bm_` and 32 lowercase hex digits.
    pub fn next_id(&mut self) -> String {
        let high = self.step();
        let low = self.step();
        format!("bm_{high:016x}{low:016x}")
    }

    fn step(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }
}
