//! App sections enter the sidebar once; the document owns their order after that.
//! Placement and its durable receipt share the document's SQLite transaction.

use cmux_layout_reducer::sidebar_doc::{Doc, Op, Region, Section, SectionKind, SectionPlace};
use rusqlite::{Connection, OptionalExtension, Transaction};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::catalog::Package;
use super::mirror::Source;
use super::supervisor::{ApiError, Supervisor};
use crate::WorkspaceMutation;

const INITIALIZED: &str = "apps.sidebar.initialized";

impl Supervisor {
    /// Reconcile after startup, install/show and local reload, outside the app lock.
    pub(super) fn reconcile_sidebar(&self) {
        let sections = {
            let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            inner
                .catalog
                .packages
                .values()
                .filter(|package| {
                    package.source != Source::Default
                        && (package.source == Source::Local
                            || inner.mirror.sidebar_auto_place.contains(&package.id))
                        && inner.mirror.apps.get(&package.id).is_some_and(|record| {
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
pub(super) fn sections(package: &Package) -> Vec<Section> {
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
) -> anyhow::Result<Value> {
    if automatic {
        let unchanged = mux.read_registry_state(|connection| {
            anyhow::ensure!(
                has_receipt(connection, INITIALIZED)?,
                "sidebar placement not initialized"
            );
            let mut all_seen = true;
            for section in sections {
                if let Some(key) = receipt_key(section)
                    && !has_receipt(connection, &key)?
                {
                    all_seen = false;
                    break;
                }
            }
            if all_seen {
                crate::state::sidebar_doc_store::with_doc(connection, |doc| {
                    Ok(Some(json!({"revision": doc.revision.to_string(), "inverse": []})))
                })
            } else {
                Ok(None)
            }
        })?;
        if let Some(result) = unchanged {
            return Ok(result);
        }
    }
    mux.commit_sidebar_ops(
        &WorkspaceMutation::daemon_local("apps.sidebar.place"),
        "apps.sidebar.place",
        &json!({"sections": sections, "automatic": automatic}),
        |transaction, doc| placement_ops(transaction, doc, sections, automatic),
    )
    .map(|commit| commit.result)
}

/// Seed receipts once, before startup installs any defaults or customization.
/// Only metadata is written: an upgrade must not add, move or remove sections. So it is
/// written as metadata, not as a sidebar commit: it takes no resource revision and
/// publishes no change (a fresh daemon's first real change is revision 1).
pub(super) fn initialize(mux: &crate::Mux, existing: &[Section]) -> anyhow::Result<()> {
    if mux.read_registry_state(|connection| has_receipt(connection, INITIALIZED))? {
        return Ok(());
    }
    mux.write_registry_meta(|transaction| {
        // A migration that failed at open leaves no document: no marker, so the next
        // start initializes again and automatic placement stays off meanwhile.
        anyhow::ensure!(
            crate::state::sidebar_doc_store::is_migrated(transaction)?,
            "sidebar document unavailable: its migration did not complete"
        );
        if !has_receipt(transaction, INITIALIZED)? {
            for section in existing {
                if let Some(key) = receipt_key(section) {
                    write_receipt(transaction, &key)?;
                }
            }
            write_receipt(transaction, INITIALIZED)?;
        }
        Ok(())
    })
}

fn receipt_key(section: &Section) -> Option<String> {
    let SectionKind::App { contribution } = &section.kind else { return None };
    Some(format!("apps.sidebar.placed:{contribution}"))
}

fn has_receipt(connection: &Connection, key: &str) -> anyhow::Result<bool> {
    Ok(connection
        .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| row.get::<_, String>(0))
        .optional()?
        .is_some())
}

fn write_receipt(transaction: &Transaction<'_>, key: &str) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, '1') ON CONFLICT(key) DO NOTHING",
        [key],
    )?;
    Ok(())
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
        let Some(key) = receipt_key(section) else { continue };
        if automatic && has_receipt(transaction, &key)? {
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
        write_receipt(transaction, &key)?;
    }
    Ok(ops)
}

#[cfg(test)]
mod tests;
