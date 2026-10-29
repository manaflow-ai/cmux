//! The daemon's diagnostic sites: each call site that
//! blocked where blocking is disallowed, each priority inversion, each
//! request method that ran past the watchdog threshold and each holder-link
//! frame or journal commit that ran past its hang tier, kept once per daemon
//! life and pushed to the app's hang reports as one `server-diagnostic-site`
//! event (spec/events.md; the subscribe stream adds its `event` name).
//!
//! A site names no path: a blocking site is its crate, a hash of its file
//! from the crate's folder on (the same on every machine, and never the
//! person's home folder or a registry path) and its line, as the app's
//! blocking samples name image UUIDs and offsets, never file names.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use cmux_threads::blocking::{BlockingKind, FirstSite};
use serde_json::{Value, json};

use crate::panic_free::RecoverPoison;

/// The most sites one daemon life keeps: the blocking site table's 256 and
/// as many request methods.
pub const MAX_DIAGNOSTIC_SITES: usize = 512;

/// The crate of a site whose path has no `<crate>/src/` folder, or whose
/// folder is not a plain crate name.
const OTHER_CRATE: &str = "other";

/// One site, first seen in this daemon life.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DiagnosticSite {
    /// A blocking call or a priority inversion
    /// ([`BlockingKind::PriorityInversion`]) at one call site.
    Blocking {
        kind: BlockingKind,
        /// The crate folder's name without its version (`cmux-tui-core`,
        /// `tokio`, `std`), or `other`.
        crate_name: &'static str,
        /// FNV-1a of the file's path from the crate folder on.
        file_hash: u64,
        line: u32,
        /// A work item's wait for other work.
        lane_sync: bool,
    },
    /// A watched run past its tier: a request method past the watchdog
    /// threshold (`scope` `request`), or a holder-link frame or a journal
    /// commit past its hang tier (`holder-link`, `journal-writer`).
    Hang { scope: &'static str, method: &'static str },
}

/// What a site is the same as: a blocking site by its crate, file and line
/// (whatever kind was seen first), a hang by its scope and method.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum SiteKey {
    Blocking { crate_name: &'static str, file_hash: u64, line: u32 },
    Hang { scope: &'static str, method: &'static str },
}

impl DiagnosticSite {
    /// The site of one first sighting, with its path reduced to crate and hash.
    pub fn of(first: FirstSite) -> Self {
        match first {
            FirstSite::Blocking { file, line, kind, lane_sync, .. } => {
                let (crate_name, file_hash) = crate_and_hash(file);
                Self::Blocking { kind, crate_name, file_hash, line, lane_sync }
            }
            FirstSite::Hang { scope, name } => Self::Hang { scope, method: name },
        }
    }

    fn key(&self) -> SiteKey {
        match *self {
            Self::Blocking { crate_name, file_hash, line, .. } => {
                SiteKey::Blocking { crate_name, file_hash, line }
            }
            Self::Hang { scope, method } => SiteKey::Hang { scope, method },
        }
    }

    /// The fields of its `server-diagnostic-site` event line (spec/events.md),
    /// all but `event`.
    pub fn fields(&self) -> Value {
        match *self {
            Self::Blocking { kind, crate_name, file_hash, line, lane_sync } => json!({
                "family": if kind == BlockingKind::PriorityInversion { "inversion" } else { "blocking" },
                "kind": kind.as_str(),
                "crate": crate_name,
                "file_hash": format!("{file_hash:016x}"),
                "line": line,
                "lane_sync": lane_sync,
            }),
            Self::Hang { scope, method } => json!({
                "family": "hang",
                "kind": scope,
                // `frame:apps` -> `frame.apps`: report text holds no colon.
                "method": method.replace(':', "."),
            }),
        }
    }
}

/// The crate folder of `file` (the folder before its last `src`), without a
/// `-<version>` suffix, and the FNV-1a hash of the path from that folder on
/// with `/` separators. A path with no such folder hashes its file name.
fn crate_and_hash(file: &'static str) -> (&'static str, u64) {
    let parts: Vec<&'static str> = file.split(['/', '\\']).collect();
    let folder = parts.iter().rposition(|part| *part == "src").filter(|src| *src > 0);
    let (crate_name, from) = match folder {
        Some(src) => (crate_name(parts[src - 1]), src - 1),
        None => (OTHER_CRATE, parts.len().saturating_sub(1)),
    };
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for (index, part) in parts[from..].iter().enumerate() {
        let separator = if index == 0 { None } else { Some(b'/') };
        for byte in separator.into_iter().chain(part.bytes()) {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0100_0000_01b3);
        }
    }
    (crate_name, hash)
}

/// `tokio-1.38.0` -> `tokio`; a folder that is not a plain lowercase crate
/// name (a git checkout, a hash) -> `other`.
fn crate_name(folder: &'static str) -> &'static str {
    let name = match folder.rfind('-') {
        Some(dash) if folder[dash + 1..].starts_with(|c: char| c.is_ascii_digit()) => {
            &folder[..dash]
        }
        _ => folder,
    };
    let plain = (1..=32).contains(&name.len())
        && name.starts_with(|c: char| c.is_ascii_lowercase())
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_');
    if plain { name } else { OTHER_CRATE }
}

/// The sites of this daemon life, first seen first.
#[derive(Debug, Default)]
pub struct DiagnosticSites {
    // Lock carve-out: taken only by the `mux-diag-sites` forwarder when a
    // first sighting arrives (at most once per site) and by a `subscribe`
    // that replays the sites; never on a request's path, and nothing is
    // called under it.
    state: Mutex<SiteList>,
}

#[derive(Debug, Default)]
struct SiteList {
    seen: HashSet<SiteKey>,
    sites: Vec<Arc<DiagnosticSite>>,
    /// New sites that found the list full.
    overflow: u64,
}

impl DiagnosticSites {
    /// Keeps `site` when it is new and the list has room, and returns it.
    pub fn note(&self, site: DiagnosticSite) -> Option<Arc<DiagnosticSite>> {
        let mut state = self.state.lock().recover_poison();
        if state.seen.contains(&site.key()) {
            return None;
        }
        if state.sites.len() == MAX_DIAGNOSTIC_SITES {
            state.overflow += 1;
            return None;
        }
        state.seen.insert(site.key());
        let site = Arc::new(site);
        state.sites.push(site.clone());
        Some(site)
    }

    /// The kept sites, first seen first.
    pub fn snapshot(&self) -> Vec<Arc<DiagnosticSite>> {
        self.state.lock().recover_poison().sites.clone()
    }

    /// New sites dropped because the list was full.
    pub fn overflow(&self) -> u64 {
        self.state.lock().recover_poison().overflow
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blocking(file: &'static str, line: u32, kind: BlockingKind) -> DiagnosticSite {
        DiagnosticSite::of(FirstSite::Blocking { file, line, column: 9, kind, lane_sync: false })
    }

    #[test]
    fn a_site_names_its_crate_and_a_machine_independent_hash_never_its_path() {
        let workspace = blocking("crates/cmux-tui-core/src/server/x.rs", 7, BlockingKind::Fs);
        let absolute = blocking(
            "/Users/mina/fun/cmux/cmux-tui/crates/cmux-tui-core/src/server/x.rs",
            7,
            BlockingKind::Fs,
        );
        let windows = blocking(
            r"C:\Users\mina\cmux\crates\cmux-tui-core\src\server\x.rs",
            7,
            BlockingKind::Fs,
        );
        assert_eq!(workspace, absolute);
        assert_eq!(workspace, windows);
        let DiagnosticSite::Blocking { crate_name, .. } = workspace else { panic!("blocking") };
        assert_eq!(crate_name, "cmux-tui-core");
        let text = absolute.fields().to_string();
        for private in ["mina", "Users", "fun", "x.rs", "/"] {
            assert!(!text.contains(private), "{private} in {text}");
        }
        let value = absolute.fields();
        assert_eq!(value["family"], "blocking");
        assert_eq!(value["kind"], "fs");
        assert_eq!(value["line"], 7);
        assert_eq!(value["file_hash"].as_str().map(str::len), Some(16));
    }

    #[test]
    fn registry_std_and_unknown_folders_reduce_to_a_crate_name_or_other() {
        let name = |file| match blocking(file, 1, BlockingKind::Sleep) {
            DiagnosticSite::Blocking { crate_name, .. } => crate_name,
            DiagnosticSite::Hang { .. } => unreachable!(),
        };
        assert_eq!(
            name(
                "/home/mina/.cargo/registry/src/index.crates.io-6f17d22bba15001f/tokio-1.38.0/src/rt/mod.rs"
            ),
            "tokio"
        );
        assert_eq!(
            name("/rustc/90b35a6239c3d8bdabc530a6a0816f7ff89a0aaf/library/std/src/thread/mod.rs"),
            "std"
        );
        assert_eq!(
            name("/home/mina/.cargo/git/checkouts/Some_Fork-ab12/9f3e2c1/src/lib.rs"),
            "other"
        );
        assert_eq!(name("build.rs"), "other");
    }

    #[test]
    fn inversions_and_hangs_have_their_family_and_no_colon() {
        let inversion =
            blocking("crates/cmux-threads/src/sync.rs", 3, BlockingKind::PriorityInversion);
        assert_eq!(inversion.fields()["family"], "inversion");
        assert_eq!(inversion.fields()["kind"], "priority-inversion");
        let hang =
            DiagnosticSite::of(FirstSite::Hang { scope: "request", name: "frame:agent-session" });
        assert_eq!(
            hang.fields(),
            json!({"family": "hang", "kind": "request", "method": "frame.agent-session"})
        );
        let holder = DiagnosticSite::of(FirstSite::Hang { scope: "holder-link", name: "data" });
        assert_eq!(
            holder.fields(),
            json!({"family": "hang", "kind": "holder-link", "method": "data"})
        );
    }

    #[test]
    fn a_site_is_kept_once_whatever_kind_came_later_and_the_list_is_bounded() {
        let sites = DiagnosticSites::default();
        let kept = |site| sites.note(site).is_some();
        assert!(kept(blocking("crates/a/src/x.rs", 1, BlockingKind::Fs)));
        assert!(!kept(blocking("crates/a/src/x.rs", 1, BlockingKind::Sleep)), "same site");
        assert!(kept(blocking("crates/a/src/x.rs", 2, BlockingKind::Fs)), "another line");
        let hang = DiagnosticSite::Hang { scope: "request", method: "list-workspaces" };
        assert!(kept(hang.clone()));
        assert!(!kept(hang));
        // The same name in another scope is another site.
        assert!(kept(DiagnosticSite::Hang { scope: "journal-writer", method: "list-workspaces" }));
        assert_eq!(sites.snapshot().len(), 4);
        for line in 0..u32::try_from(MAX_DIAGNOSTIC_SITES).unwrap() {
            kept(blocking("crates/b/src/y.rs", line, BlockingKind::Fs));
        }
        assert_eq!(sites.snapshot().len(), MAX_DIAGNOSTIC_SITES);
        assert_eq!(sites.overflow(), 4);
    }
}
