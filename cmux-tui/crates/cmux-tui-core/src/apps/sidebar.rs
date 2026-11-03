//! App sections enter the sidebar once; the document owns their order after that.
//! Placement and its durable receipt share the document's SQLite transaction.

use cmux_layout_reducer::sidebar_doc::{Doc, Op, Region, Section, SectionKind, SectionPlace};
use rusqlite::{OptionalExtension, Transaction};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::catalog::Package;
use super::supervisor::{ApiError, Supervisor};
use crate::WorkspaceMutation;

impl Supervisor {
    /// Reconcile after startup, install/show and local reload, outside the app lock.
    pub(super) fn reconcile_sidebar(&self) {
        let sections =
            {
                let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                inner
                    .catalog
                    .packages
                    .values()
                    .filter(|package| {
                        inner.mirror.apps.get(&package.id).is_some_and(|record| {
                            record.installed && record.enabled && !record.hidden
                        })
                    })
                    .flat_map(sections)
                    .collect::<Vec<_>>()
            };
        if !sections.is_empty()
            && let Err(error) = self.router.place_sidebar_sections(&sections, true)
        {
            eprintln!("cmux-tui: app sidebar placement: {}", error.message);
        }
    }

    /// Explicit agent placement can restore a section the person removed.
    pub fn place_sidebar(
        &self,
        contribution: &str,
        region: Option<Region>,
    ) -> Result<Value, ApiError> {
        if region
            .as_ref()
            .is_some_and(|region| !matches!(region, Region::Top | Region::Middle | Region::Bottom))
        {
            return Err(ApiError::new("bad-request", "region must be top, middle or bottom"));
        }
        let (app, _) = contribution
            .split_once('#')
            .ok_or_else(|| ApiError::new("bad-request", "expected <app>#<section>"))?;
        let mut section = {
            let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if !inner
                .mirror
                .apps
                .get(app)
                .is_some_and(|record| record.installed && record.enabled && !record.hidden)
            {
                return Err(ApiError::new("apps.unavailable", "app must be installed and visible"));
            }
            inner.catalog.packages.get(app).into_iter().flat_map(sections).find(|section| {
                matches!(&section.kind, SectionKind::App { contribution: name } if name == contribution)
            }).ok_or_else(|| ApiError::new("apps.section.unknown", "no such sidebar section"))?
        };
        if let Some(region) = region {
            section.scroll =
                cmux_layout_reducer::sidebar_doc::Scroll::default_for(&section.kind, &region);
            section.region = region;
        }
        self.router.place_sidebar_sections(&[section], false)
    }
}

/// v2 identifies a section by its interface; v1 by its contribution id,
/// matching AppManifest's native scene provider.
fn sections(package: &Package) -> Vec<Section> {
    let manifest = &package.manifest;
    let entries: Vec<(&str, &Value)> =
        if let Some(entry) = manifest.pointer("/implements/cmux.section~11") {
            vec![("cmux.section/1", entry.get("options").unwrap_or(&Value::Null))]
        } else {
            manifest
                .pointer("/contributes/sidebarSections")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|entry| Some((entry.get("id")?.as_str()?, entry)))
                .collect()
        };
    entries
        .into_iter()
        .map(|(id, options)| {
            let contribution = format!("{}#{id}", package.id);
            let digest = Sha256::digest(contribution.as_bytes());
            let id = format!("sec_app_{digest:x}");
            let region = options
                .get("defaultRegion")
                .cloned()
                .and_then(|value| serde_json::from_value(value).ok())
                .unwrap_or(Region::Middle);
            let mut section = Section::new(&id, SectionKind::App { contribution }, region);
            // The scene provider resolves the current localized manifest title.
            // A person can still rename the document section after placement.
            section.max_rows = options.get("maxRows").and_then(Value::as_i64);
            section
        })
        .collect()
}

pub(super) fn place(
    mux: &crate::Mux,
    sections: &[Section],
    automatic: bool,
) -> anyhow::Result<crate::state::store::StateCommit> {
    mux.commit_sidebar_ops(
        &WorkspaceMutation::daemon_local("apps.sidebar.place"),
        "apps.sidebar.place",
        &json!({"sections": sections, "automatic": automatic}),
        |transaction, doc| placement_ops(transaction, doc, sections, automatic),
    )
}

fn placement_ops(
    transaction: &Transaction<'_>,
    doc: &Doc,
    sections: &[Section],
    automatic: bool,
) -> anyhow::Result<Vec<Op>> {
    let mut ops = Vec::new();
    for section in sections {
        let SectionKind::App { contribution } = &section.kind else { continue };
        let key = format!("apps.sidebar.placed:{contribution}");
        let seen = transaction
            .query_row("SELECT value FROM meta WHERE key = ?1", [&key], |row| {
                row.get::<_, String>(0)
            })
            .optional()?
            .is_some();
        if automatic && seen {
            continue;
        }
        let existing = doc.sections().iter().find(|section| {
            matches!(&section.kind, SectionKind::App { contribution: name } if name == contribution)
        });
        if let Some(existing) = existing {
            if !automatic && existing.region != section.region {
                ops.push(Op::SectionMove {
                    id: existing.id.clone(),
                    place: SectionPlace {
                        region: Some(section.region.clone()),
                        ..Default::default()
                    },
                });
            }
        } else {
            ops.push(Op::SectionAdd { section: section.clone(), place: SectionPlace::default() });
        }
        transaction.execute(
            "INSERT INTO meta(key, value) VALUES(?1, '1') ON CONFLICT(key) DO NOTHING",
            [&key],
        )?;
    }
    Ok(ops)
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_layout_reducer::sidebar_doc::reduce;

    fn package() -> Package {
        Package {
            id: "local/customize".into(),
            version: "1.0.0".into(),
            tier: super::super::mirror::Tier::Unverified,
            source: super::super::mirror::Source::Local,
            dir: Default::default(),
            manifest: json!({"implements": {"cmux.section/1": {
                "export": "render", "title": "Recent PRs",
                "options": {"defaultRegion": "bottom", "maxRows": 8}
            }}}),
        }
    }

    fn connection() -> rusqlite::Connection {
        let connection = rusqlite::Connection::open_in_memory().unwrap();
        connection
            .execute_batch("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            .unwrap();
        connection
    }

    fn apply(doc: &mut Doc, ops: &[Op]) {
        reduce::apply_in_place(doc, ops, &mut || "unused".into()).unwrap();
    }

    #[test]
    fn customize_bottom_is_placed_once_and_removal_survives_reload_and_restart() {
        let mut connection = connection();
        let sections = sections(&package());
        let id = sections[0].id.clone();
        let mut doc = Doc::from_parts(0, vec![], vec![]);
        let tx = connection.transaction().unwrap();
        let ops = placement_ops(&tx, &doc, &sections, true).unwrap();
        apply(&mut doc, &ops);
        tx.commit().unwrap();
        assert_eq!(doc.section(&id).unwrap().region, Region::Bottom);
        assert_eq!(doc.section(&id).unwrap().max_rows, Some(8));
        apply(&mut doc, &[Op::SectionRemove { id: id.clone() }]);
        // Re-read the durable receipt in a new transaction. No process-local
        // placement set can bring the person's removed section back.
        for _ in 0..2 {
            let tx = connection.transaction().unwrap();
            assert!(placement_ops(&tx, &doc, &sections, true).unwrap().is_empty());
            tx.commit().unwrap();
        }
        assert!(doc.section(&id).is_none());
        let tx = connection.transaction().unwrap();
        let restore = placement_ops(&tx, &doc, &sections, false).unwrap();
        apply(&mut doc, &restore);
        tx.commit().unwrap();
        assert!(doc.section(&id).is_some(), "explicit placement restores it");
    }

    #[test]
    fn automatic_placement_preserves_a_move_and_adopts_an_existing_contribution() {
        let mut connection = connection();
        let sections = sections(&package());
        let mut existing = sections[0].clone();
        existing.id = "sec_persons_section".into();
        existing.region = Region::Top;
        existing.order = "a0".into();
        let doc = Doc::from_parts(0, vec![existing.clone()], vec![]);
        let tx = connection.transaction().unwrap();
        assert!(placement_ops(&tx, &doc, &sections, true).unwrap().is_empty());
        tx.commit().unwrap();
        let tx = connection.transaction().unwrap();
        assert!(placement_ops(&tx, &doc, &sections, true).unwrap().is_empty());
        assert_eq!(doc.section(&existing.id).unwrap().region, Region::Top);
        assert!(matches!(placement_ops(&tx, &doc, &sections, false).unwrap().as_slice(),
            [Op::SectionMove { id, .. }] if id == &existing.id));
    }

    #[test]
    fn a_failed_document_transaction_does_not_record_placement() {
        let mut connection = connection();
        let sections = sections(&package());
        let doc = Doc::from_parts(0, vec![], vec![]);
        {
            let tx = connection.transaction().unwrap();
            assert_eq!(placement_ops(&tx, &doc, &sections, true).unwrap().len(), 1);
            // Dropping a rejected document transaction rolls back the receipt too.
        }
        let tx = connection.transaction().unwrap();
        assert_eq!(placement_ops(&tx, &doc, &sections, true).unwrap().len(), 1);
    }

    #[test]
    fn v1_contribution_ids_and_v2_interface_ids_match_the_scene_provider() {
        let mut app = package();
        app.manifest = json!({"contributes": {"sidebarSections": [
            {"id":"prs", "title":{"en":"PRs"}, "defaultRegion":"bottom", "render":"render"},
            {"id":"other", "title":"Other", "render":"render"}
        ]}});
        let sections = sections(&app);
        assert!(
            matches!(&sections[0].kind, SectionKind::App { contribution } if contribution == "local/customize#prs")
        );
        assert_eq!(sections[0].region, Region::Bottom);
        assert_eq!(sections[1].region, Region::Middle);
    }
}
