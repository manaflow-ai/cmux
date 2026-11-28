//! Community index tests: a fixture registry, no network.

use std::sync::Mutex;

use serde_json::{Value, json};

use super::*;

const SHA_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const SHA_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

pub(crate) fn listing(owner: &str, repo: &str, commit: &str) -> Value {
    json!({
        "host": "github.com", "owner": owner, "repo": repo, "path": "",
        "ref": format!("github.com/{owner}/{repo}"), "kind": "extension",
        "repository": format!("https://github.com/{owner}/{repo}"),
        "id": format!("{}/{repo}", owner.to_lowercase()), "name": format!("{repo} name"),
        "tagline": "Short line", "description": format!("{repo} does things"),
        "categories": ["productivity"], "iconUrl": "https://example.com/i.png",
        "screenshots": ["https://example.com/s.png"], "license": "MIT",
        "publisher": { "name": format!("{owner} Inc"), "url": "https://example.com" },
        "version": "1.2.0", "minCmux": "^2.0", "commit": commit,
        "reviewedAt": "2026-11-10T00:00:00Z", "updatedAt": "2026-11-12T00:00:00Z",
        "stars": 7, "installs": 42, "readme": format!("# {repo}\n\nHello"),
        "versions": [{ "version": "1.2.0", "tag": "v1.2.0", "commit": commit, "date": "2026-11-12" }],
        "installUrl": "x", "pageUrl": format!("https://cmux.com/extensions/{owner}/{repo}")
    })
}

/// One fixture URL and its body or error.
pub(crate) type Page = (String, Result<Vec<u8>, String>);

/// Answers URLs from a table; counts calls; unknown URLs fail.
#[derive(Default)]
pub(crate) struct FakeRegistry {
    pub pages: Mutex<Vec<Page>>,
    pub calls: Mutex<Vec<String>>,
}

impl FakeRegistry {
    pub fn with(pages: Vec<(&str, Result<Value, &str>)>) -> Arc<Self> {
        let pages = pages
            .into_iter()
            .map(|(url, body)| {
                (
                    url.to_string(),
                    body.map(|v| serde_json::to_vec(&v).unwrap()).map_err(str::to_string),
                )
            })
            .collect();
        Arc::new(Self { pages: Mutex::new(pages), calls: Mutex::default() })
    }
}

impl RegistryFetch for FakeRegistry {
    fn get(&self, url: &str) -> Result<Vec<u8>, String> {
        self.calls.lock().unwrap().push(url.to_string());
        self.pages
            .lock()
            .unwrap()
            .iter()
            .find(|(u, _)| u == url)
            .map(|(_, body)| body.clone())
            .unwrap_or_else(|| Err("404".into()))
    }
}

const BASE: &str = "https://registry.test";

fn ext_url(cursor: Option<&str>) -> String {
    match cursor {
        None => format!("{BASE}/v1/extensions?status=reviewed&limit=100"),
        Some(c) => format!("{BASE}/v1/extensions?status=reviewed&limit=100&cursor={c}"),
    }
}

fn temp_dir() -> PathBuf {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-community-test-{}",
        bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn a_listing_becomes_a_row_with_the_wire_fields() {
    let row = row(&listing("Acme", "notes", SHA_A), &Installed::default()).unwrap();
    let wire = serde_json::to_value(&row).unwrap();
    assert_eq!(wire["source"], "community");
    assert_eq!(wire["ref"], "github.com/Acme/notes");
    assert_eq!(wire["app"], "acme/notes");
    assert_eq!(wire["kind"], "extension");
    assert_eq!(wire["tagline"], "Short line");
    assert_eq!(wire["author"], "Acme Inc");
    assert_eq!(wire["author_url"], "https://example.com");
    assert_eq!(wire["downloads"], 42);
    assert_eq!(wire["stars"], 7);
    assert_eq!(wire["updated_at"], "2026-11-12T00:00:00Z");
    assert_eq!(wire["latest_release"]["tag"], "v1.2.0");
    assert_eq!(wire["install_app"], format!("github.com/Acme/notes@{SHA_A}"));
    assert_eq!(wire["installed"], false);
    assert!(wire.get("readme").is_none(), "list rows carry no readme");
    let detail = serde_json::to_value(
        detail(&listing("Acme", "notes", SHA_A), &Installed::default()).unwrap(),
    )
    .unwrap();
    assert_eq!(detail["readme"], "# notes\n\nHello");
    assert_eq!(detail["screenshots"][0], "https://example.com/s.png");
    assert_eq!(detail["versions"][0]["version"], "1.2.0");
}

#[test]
fn a_listing_without_a_reviewed_commit_or_a_good_ref_is_dropped() {
    assert!(row(&listing("Acme", "notes", "main"), &Installed::default()).is_none());
    let mut bad = listing("Acme", "notes", SHA_A);
    bad["ref"] = json!("github.com/../x");
    assert!(row(&bad, &Installed::default()).is_none());
}

#[test]
fn the_fetch_follows_cursors_up_to_the_page_bound() {
    let mut pages: Vec<(String, Result<Value, &str>)> = Vec::new();
    for page in 0..(MAX_PAGES + 2) {
        let cursor = (page > 0).then(|| format!("c{page}"));
        let url = ext_url(cursor.as_deref());
        let body = json!({ "items": [listing("Acme", &format!("r{page}"), SHA_A)], "next": format!("c{}", page + 1) });
        pages.push((url, Ok(body)));
    }
    let registry = FakeRegistry::with(pages.iter().map(|(u, b)| (u.as_str(), b.clone())).collect());
    let items = fetch_index(registry.as_ref(), BASE).unwrap();
    assert_eq!(items.len(), MAX_PAGES);
    let calls = registry.calls.lock().unwrap();
    assert_eq!(calls.iter().filter(|u| u.contains("/v1/extensions")).count(), MAX_PAGES);
}

#[test]
fn an_oversized_page_fails_the_fetch() {
    struct Huge;
    impl RegistryFetch for Huge {
        fn get(&self, _: &str) -> Result<Vec<u8>, String> {
            Ok(vec![b' '; MAX_PAGE_BYTES + 1])
        }
    }
    assert!(fetch_index(&Huge, BASE).unwrap_err().contains("8 MiB"));
}

#[test]
fn only_reviewed_listings_are_kept_and_no_status_counts_as_reviewed() {
    let mut community = listing("Acme", "draft", SHA_A);
    community["status"] = json!("community");
    let mut reviewed_one = listing("Acme", "notes", SHA_A);
    reviewed_one["status"] = json!("reviewed");
    let page = json!({ "items": [community, reviewed_one, listing("Acme", "old", SHA_A)] });
    let registry = FakeRegistry::with(vec![(ext_url(None).as_str(), Ok(page))]);
    let items = fetch_index(registry.as_ref(), BASE).unwrap();
    let repos: Vec<&str> = items.iter().filter_map(|i| i["repo"].as_str()).collect();
    assert_eq!(repos, ["notes", "old"]);
    assert!(registry.calls.lock().unwrap()[0].contains("status=reviewed"));
}

#[test]
fn setups_are_best_effort_and_extensions_are_required() {
    let ok = json!({ "items": [listing("Acme", "notes", SHA_A)] });
    let registry = FakeRegistry::with(vec![(ext_url(None).as_str(), Ok(ok))]);
    assert_eq!(fetch_index(registry.as_ref(), BASE).unwrap().len(), 1);
    let registry = FakeRegistry::with(vec![(ext_url(None).as_str(), Err("500"))]);
    assert!(fetch_index(registry.as_ref(), BASE).is_err());
}

#[test]
fn the_cache_is_served_offline_and_a_failure_keeps_it() {
    let dir = temp_dir();
    let ok = json!({ "items": [listing("Acme", "notes", SHA_A)] });
    let registry = FakeRegistry::with(vec![(ext_url(None).as_str(), Ok(ok))]);
    let community = Community::new(Some(&dir), BASE, registry);
    let (status, start) = community.status(false, true);
    assert!(status.index.is_none() && status.stale && start);
    community.refresh().unwrap();
    let (status, start) = community.status(false, true);
    assert_eq!(status.index.unwrap().items.len(), 1);
    assert!(!status.stale && !start, "a fresh cache starts no fetch");

    // A new daemon, offline: the disk cache answers; a failed refresh keeps it.
    let offline = FakeRegistry::with(vec![]);
    let community = Community::new(Some(&dir), BASE, offline);
    let (status, _) = community.status(true, true);
    assert_eq!(status.index.as_ref().unwrap().items.len(), 1);
    assert!(community.refresh().is_err());
    let (status, start) = community.status(false, true);
    assert_eq!(status.index.unwrap().items.len(), 1);
    assert!(status.error.is_some());
    assert!(!start, "fresh cache, and a failure backs off");

    // A cache of another registry is not served.
    let other = Community::new(Some(&dir), "https://elsewhere.test", FakeRegistry::with(vec![]));
    assert!(other.status(false, false).0.index.is_none());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_stale_cache_starts_one_refresh_and_backs_off_after_a_failure() {
    let dir = temp_dir();
    let stale = Index {
        base: BASE.into(),
        fetched_at: now_ms() - TTL.as_millis() as u64 - 1,
        items: vec![listing("Acme", "notes", SHA_A)],
    };
    std::fs::create_dir_all(dir.join("apps/community")).unwrap();
    std::fs::write(dir.join("apps/community/index.json"), serde_json::to_vec(&stale).unwrap())
        .unwrap();
    let community = Community::new(Some(&dir), BASE, FakeRegistry::with(vec![]));
    let (status, start) = community.status(false, true);
    assert!(status.stale && start && status.index.is_some());
    assert!(!community.status(false, true).1, "one refresh at a time");
    let _ = community.refresh();
    assert!(!community.status(false, true).1, "a failed fetch waits RETRY_AFTER");
    assert!(community.status(true, true).1, "refresh: true still fetches");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn synced_records_are_checked() {
    let good = SyncRecord {
        reference: "github.com/acme/notes".into(),
        kind: "extension".into(),
        tag: Some("v1.0.0".into()),
        commit: SHA_B.into(),
        app: None,
        name: None,
    };
    assert!(good.check().is_ok());
    assert!(SyncRecord { commit: "main".into(), ..good.clone() }.check().is_err());
    assert!(SyncRecord { kind: "binary".into(), ..good.clone() }.check().is_err());
    assert!(SyncRecord { reference: "acme/notes".into(), ..good }.check().is_err());
}

#[test]
fn a_named_registry_passes_the_gate_and_others_do_not() {
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    let base = "https://extensions-registry-named-test.org".to_owned();
    assert_eq!(named_registry_base(Some(base.clone())), base);
    // A plain-http registry is refused, falls back to the default, and is not let through.
    let plain = "http://extensions-registry-plain-test.org".to_owned();
    assert_eq!(named_registry_base(Some(plain)), DEFAULT_REGISTRY);
    assert!(cmux_egress::check("extensions-registry-named-test.org", "test").is_ok());
    assert!(cmux_egress::check("extensions-registry-plain-test.org", "test").is_err());
    assert!(cmux_egress::check("unrelated-extensions-registry-test.org", "test").is_err());
}
