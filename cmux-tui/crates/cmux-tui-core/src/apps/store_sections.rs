//! The App Store's shelves (`cmux.apps.catalog.sections`) and each app's
//! release notes (`versions` and `whats_new` on `catalog.get`), so the
//! native view and the page show what the owner decides and carry no store
//! logic of their own.
//!
//! - Sections are over the store shelf ([`Shelf::Store`]): `featured` (the
//!   curated first-party order, then the rest by name), `recent` (newest
//!   version date first) and one `category` section per category present.
//!   Titles are l10n keys; Rust never sends English for the view to show.
//! - Release notes come from the package's `catalog/whats-new.json`
//!   (`cmux_app_manifest::whats_new`, written at build time from the repo's
//!   merged PRs). A repository extension's versions come from its registry
//!   row instead (cut 3); with no file the listing answers its one version
//!   and no `whats_new`.

use std::collections::BTreeMap;

use cmux_app_manifest::whats_new::{VersionRow, WHATS_NEW_FILE, WhatsNew};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::catalog::Package;
use super::store::{APP_STORE, Shelf, bad_request, text};
use super::supervisor::{ApiError, Supervisor};

/// Featured first, in this order, when present (Leo's store: Cloud first).
const CURATED: [&str; 1] = ["cmux/cloud"];
const DEFAULT_SECTION_LIMIT: usize = 20;
const MAX_SECTION_LIMIT: usize = 200;

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct SectionsParams {
    /// One section's next page; every section's first page when absent.
    section: Option<String>,
    /// Opaque cursor from that section's `next_cursor`.
    cursor: Option<String>,
    /// Apps per section, 1 to 200; default 20.
    limit: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum SectionKind {
    Featured,
    Recent,
    Category,
}

#[derive(Debug, Serialize)]
pub(super) struct Section {
    id: String,
    kind: SectionKind,
    /// The l10n key of the section's title.
    title_key: String,
    /// App ids in the section's order.
    apps: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    next_cursor: Option<String>,
    /// The category a `category` section lists.
    #[serde(skip_serializing_if = "Option::is_none")]
    category: Option<String>,
}

#[derive(Debug, Serialize)]
pub(super) struct SectionsResult {
    sections: Vec<Section>,
    /// The install mirror revision when the shelf was read.
    revision: u64,
}

/// An app's release notes for `catalog.get`: its versions, newest first,
/// and What's New of its current version.
pub(super) struct Release {
    pub(super) versions: Vec<Value>,
    pub(super) whats_new: Option<Value>,
}

/// The package's What's New file, when it is there and well formed.
fn whats_new_file(package: &Package) -> Option<WhatsNew> {
    let bytes = package.read(WHATS_NEW_FILE)?;
    WhatsNew::from_json(&serde_json::from_slice(&bytes).ok()?)
}

/// Reads `package`'s release notes (a file read: never under the
/// supervisor lock). A file written for another version (stale) is not
/// this version's news: the listing answers only its own version.
pub(super) fn release(package: &Package) -> Release {
    let current = || vec![VersionRow { version: package.version.clone(), ..VersionRow::default() }];
    let Some(file) = whats_new_file(package).filter(|file| file.version == package.version) else {
        return Release {
            versions: current().iter().map(VersionRow::to_json).collect(),
            whats_new: None,
        };
    };
    let versions = if file.versions.is_empty() { current() } else { file.versions };
    let items: Vec<Value> =
        file.items.iter().map(|item| json!({ "title": item.title, "pr": item.pr })).collect();
    Release {
        versions: versions.iter().map(VersionRow::to_json).collect(),
        whats_new: (!items.is_empty()).then(|| json!({ "version": file.version, "items": items })),
    }
}

/// One shelf app: what the sections order by.
struct Shelved {
    id: String,
    name: String,
    categories: Vec<String>,
    /// When its current version was set (`versions[0].date_ms`).
    date_ms: Option<i64>,
}

fn shelved(package: &Package) -> Shelved {
    let current = whats_new_file(package).filter(|file| file.version == package.version);
    Shelved {
        id: package.id.clone(),
        name: package.manifest.get("name").map(text).unwrap_or_default().to_lowercase(),
        categories: package
            .manifest
            .get("categories")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|c| c.as_str().map(str::to_string))
            .collect(),
        date_ms: current.and_then(|file| file.versions.first().and_then(|row| row.date_ms)),
    }
}

/// Every section in its full order (before paging): featured, recent, then
/// the categories by name.
fn all_sections(mut apps: Vec<Shelved>) -> Vec<Section> {
    apps.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.id.cmp(&b.id)));
    let section = |id: String, kind, title_key: String, apps: Vec<String>| Section {
        id,
        kind,
        title_key,
        apps,
        next_cursor: None,
        category: None,
    };
    let rank = |id: &str| CURATED.iter().position(|c| *c == id).unwrap_or(CURATED.len());
    let mut featured: Vec<&Shelved> = apps.iter().collect();
    // Stable: the rest keep the name order.
    featured.sort_by_key(|app| rank(&app.id));
    let mut recent: Vec<&Shelved> = apps.iter().filter(|app| app.date_ms.is_some()).collect();
    recent.sort_by_key(|app| std::cmp::Reverse(app.date_ms));
    let ids = |rows: Vec<&Shelved>| -> Vec<String> {
        rows.into_iter().map(|app| app.id.clone()).collect()
    };
    let mut sections = vec![
        section(
            "featured".into(),
            SectionKind::Featured,
            "apps.store.section.featured".into(),
            ids(featured),
        ),
        section(
            "recent".into(),
            SectionKind::Recent,
            "apps.store.section.recent".into(),
            ids(recent),
        ),
    ];
    let mut categories: BTreeMap<&str, Vec<String>> = BTreeMap::new();
    for app in &apps {
        for category in &app.categories {
            let members = categories.entry(category.as_str()).or_default();
            if !members.contains(&app.id) {
                members.push(app.id.clone());
            }
        }
    }
    sections.extend(categories.into_iter().map(|(category, apps)| Section {
        category: Some(category.to_string()),
        ..section(
            format!("category:{category}"),
            SectionKind::Category,
            format!("apps.store.category.{category}"),
            apps,
        )
    }));
    sections
}

/// `section` cut to the page at `offset`, with the cursor of the next one.
fn page(mut section: Section, offset: usize, limit: usize) -> Section {
    let total = section.apps.len();
    section.apps = section.apps.into_iter().skip(offset).take(limit).collect();
    // A cursor is a wire value: never overflow on it.
    let end = offset.saturating_add(limit);
    section.next_cursor = (end < total).then(|| end.to_string());
    section
}

impl Supervisor {
    pub(super) fn catalog_sections(&self, p: SectionsParams) -> Result<SectionsResult, ApiError> {
        let offset = match (p.section.as_deref(), p.cursor.as_deref()) {
            (_, None) => 0,
            (None, Some(_)) => return Err(bad_request("a cursor needs its section")),
            (Some(_), Some(cursor)) => {
                cursor.parse::<usize>().map_err(|_| bad_request("bad cursor"))?
            }
        };
        let limit =
            p.limit.map_or(DEFAULT_SECTION_LIMIT, |l| l as usize).clamp(1, MAX_SECTION_LIMIT);
        let (packages, revision) = {
            let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let packages: Vec<Package> = inner
                .catalog
                .packages
                .values()
                .filter(|package| package.id != APP_STORE)
                .filter(|package| Shelf::of(package) == Shelf::Store)
                .cloned()
                .collect();
            (packages, inner.mirror.revision)
        };
        // The What's New files are file reads: never under the supervisor lock.
        let sections = all_sections(packages.iter().map(shelved).collect());
        let sections = match p.section {
            None => sections.into_iter().map(|s| page(s, 0, limit)).collect(),
            Some(id) => {
                let section = sections.into_iter().find(|s| s.id == id).ok_or_else(|| {
                    ApiError::new("apps.section.unknown", format!("no section {id}"))
                })?;
                vec![page(section, offset, limit)]
            }
        };
        Ok(SectionsResult { sections, revision })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app(id: &str, name: &str, categories: &[&str], date_ms: Option<i64>) -> Shelved {
        Shelved {
            id: id.into(),
            name: name.to_lowercase(),
            categories: categories.iter().map(|c| c.to_string()).collect(),
            date_ms,
        }
    }

    /// Featured keeps the curated order first, recent the newest version
    /// first, and every category on the shelf gets its section by name.
    #[test]
    fn sections_come_in_their_order_with_l10n_keys() {
        let sections = all_sections(vec![
            app("acme/zeta", "Zeta", &["productivity"], Some(30)),
            app("cmux/dev", "Dev", &["developer-tools"], Some(10)),
            app("acme/alpha", "Alpha", &["productivity", "developer-tools"], None),
            app("cmux/cloud", "Cloud", &["cloud", "developer-tools"], Some(20)),
        ]);
        let value = serde_json::to_value(&sections).unwrap();
        assert_eq!(
            value,
            json!([
                { "id": "featured", "kind": "featured", "title_key": "apps.store.section.featured",
                  "apps": ["cmux/cloud", "acme/alpha", "cmux/dev", "acme/zeta"] },
                { "id": "recent", "kind": "recent", "title_key": "apps.store.section.recent",
                  "apps": ["acme/zeta", "cmux/cloud", "cmux/dev"] },
                { "id": "category:cloud", "kind": "category", "category": "cloud",
                  "title_key": "apps.store.category.cloud", "apps": ["cmux/cloud"] },
                { "id": "category:developer-tools", "kind": "category",
                  "category": "developer-tools", "title_key": "apps.store.category.developer-tools",
                  "apps": ["acme/alpha", "cmux/cloud", "cmux/dev"] },
                { "id": "category:productivity", "kind": "category", "category": "productivity",
                  "title_key": "apps.store.category.productivity",
                  "apps": ["acme/alpha", "acme/zeta"] },
            ])
        );
    }

    #[test]
    fn a_page_names_the_cursor_of_the_next_one() {
        let section = || Section {
            id: "featured".into(),
            kind: SectionKind::Featured,
            title_key: "k".into(),
            apps: ["a", "b", "c"].map(String::from).to_vec(),
            next_cursor: None,
            category: None,
        };
        let first = page(section(), 0, 2);
        assert_eq!(
            (first.apps.clone(), first.next_cursor.as_deref()),
            (vec!["a".into(), "b".into()], Some("2"))
        );
        let last = page(section(), 2, 2);
        assert_eq!((last.apps, last.next_cursor), (vec!["c".to_string()], None));
        let past = page(section(), usize::MAX, 2);
        assert_eq!((past.apps.len(), past.next_cursor), (0, None));
    }
}
