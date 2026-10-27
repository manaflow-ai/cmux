//! The page router table (`page-router-v1`, cmux-tui/spec/page-router.json
//! and page-router.md): what each cmux page may call, and the v2 operation
//! namespaces the daemon routes to an owner outside the operation catalog.
//!
//! The spec file is the one source. The daemon embeds it here; the page
//! clients get a table generated from it (bindings/codegen/page_router.py)
//! and the page relay gets its page's entry in the `client-hello` reply.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde::Deserialize;
use serde_json::{Value, json};

const PAGE_ROUTER_JSON: &str = include_str!("../../../../spec/page-router.json");

/// Advertised by `identify`: page ids on connections, the per-page allow
/// list, and the routed v2 namespaces.
pub(crate) const PAGE_ROUTER_CAPABILITY: &str = "page-router-v1";

/// Advertised by `identify`: a page relay's `client-hello` reply carries
/// `page_events`, and a page relay whose page names events may `subscribe`
/// and hears only those events.
pub(crate) const PAGE_EVENTS_CAPABILITY: &str = "page-events-v1";

#[derive(Deserialize)]
struct Table {
    pages: BTreeMap<String, PageEntry>,
    namespaces: BTreeMap<String, NamespaceEntry>,
}

#[derive(Deserialize)]
struct PageEntry {
    read: Vec<String>,
    gesture: Vec<String>,
    confirm: Vec<String>,
    /// The subscribe events a page relay of this page hears.
    events: Vec<String>,
}

#[derive(Deserialize)]
struct NamespaceEntry {
    owner: String,
    read: Vec<String>,
    mutation: Vec<String>,
}

#[allow(
    clippy::expect_used,
    reason = "INVARIANT: the checked-in spec/page-router.json parses; every page router test reads it"
)]
fn table() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| {
        serde_json::from_str(PAGE_ROUTER_JSON).expect("spec/page-router.json is a valid table")
    })
}

/// What a page may do with one operation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PageGrant {
    /// The page may call it.
    Read,
    /// The page may call it only with the person's gesture: a host
    /// confirmation for exactly this request (`origin.confirmation.issue`),
    /// which the host mints on one real key or pointer event.
    Gesture,
    /// The page may call it only after the person approved it on a native
    /// sheet: the same confirmation, which the host mints only after the
    /// sheet (never on a click alone).
    Confirm,
    /// Not on the page's list (or the page has no entry).
    None,
}

/// A page id: 1 to 64 characters of `[a-z0-9-]`, starting with a letter.
pub(crate) fn valid_page_id(id: &str) -> bool {
    (1..=64).contains(&id.len())
        && id.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        && id.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

/// The page id of a host's page origin: `cmux-page://cmux.<page>` (the
/// app's pages; the web view sets the Origin, page script cannot change it).
pub(crate) fn page_from_origin(origin: &str) -> Option<String> {
    // The listener compares origins lowercase; so does the page id, or a
    // native client's `CMUX.history` would pass the handshake with no page.
    let origin = origin.to_ascii_lowercase();
    let page = origin.strip_prefix("cmux-page://cmux.")?;
    valid_page_id(page).then(|| page.to_owned())
}

/// Whether `page` is a page of the table (`page-credential {page}`).
pub(crate) fn known_page(page: &str) -> bool {
    table().pages.contains_key(page)
}

/// What `page` may do with `operation` (its wire name).
pub(crate) fn grant(page: &str, operation: &str) -> PageGrant {
    let Some(entry) = table().pages.get(page) else { return PageGrant::None };
    if entry.read.iter().any(|name| name == operation) {
        PageGrant::Read
    } else if entry.gesture.iter().any(|name| name == operation) {
        PageGrant::Gesture
    } else if entry.confirm.iter().any(|name| name == operation) {
        PageGrant::Confirm
    } else {
        PageGrant::None
    }
}

/// `page`'s entry for the `client-hello` reply: `{read, gesture, confirm}`
/// (all empty for a page with no entry).
pub(crate) fn page_operations(page: &str) -> Value {
    match table().pages.get(page) {
        Some(entry) => {
            json!({"read": entry.read, "gesture": entry.gesture, "confirm": entry.confirm})
        }
        None => json!({"read": [], "gesture": [], "confirm": []}),
    }
}

/// The subscribe events a page relay of `page` hears (`page-router-v1`
/// events): empty for a page with no entry or no events, and such a relay
/// gets no event stream.
pub(crate) fn page_events(page: &str) -> &'static [String] {
    table().pages.get(page).map_or(&[], |entry| entry.events.as_slice())
}

/// The refusal reason of a grant without the person's confirmation.
pub(crate) const fn missing_confirmation_reason(grant: PageGrant) -> Option<&'static str> {
    match grant {
        PageGrant::Read => None,
        PageGrant::Gesture => Some("gesture_required"),
        PageGrant::Confirm => Some("confirmation_required"),
        PageGrant::None => Some("page_not_allowed"),
    }
}

/// A routed v2 operation (not a catalog operation): its namespace's owner.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Routed {
    pub(crate) owner: &'static str,
    pub(crate) mutation: bool,
}

/// The route of `operation`, when a routed namespace names it.
pub(crate) fn routed(operation: &str) -> Option<Routed> {
    let (namespace, _) = operation.split_once('.')?;
    let entry = table().namespaces.get(namespace)?;
    let owner = entry.owner.as_str();
    if entry.read.iter().any(|name| name == operation) {
        Some(Routed { owner, mutation: false })
    } else if entry.mutation.iter().any(|name| name == operation) {
        Some(Routed { owner, mutation: true })
    } else {
        None
    }
}
