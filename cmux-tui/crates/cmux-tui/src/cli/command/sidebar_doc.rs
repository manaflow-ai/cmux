//! The sidebar document verbs of the noun-first CLI (`sidebar-doc-v1`): a
//! section's scroll mode and row limit. Each verb is one
//! `sidebar.section.update`; the app owns the other sidebar mutations.
//!
//! - `cmux sidebar section-scroll <section> fixed|flow`
//! - `cmux sidebar section-max-rows <section> <1-50>|none`

use cmux_tui_core::resource::ResourceOperation as Op;
use serde_json::{Map, Value, json};

use super::{CommandPlan, Flags, Selectors, UsageError, request};

pub(super) fn section_scroll(
    section: &str,
    scroll: &str,
    selectors: &Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    if !matches!(scroll, "fixed" | "flow") {
        return Err(UsageError::new("sidebar section-scroll takes fixed or flow"));
    }
    update(section, json!({"scroll": scroll}), selectors, flags)
}

pub(super) fn section_max_rows(
    section: &str,
    rows: &str,
    selectors: &Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let value = match rows {
        "none" => Value::Null,
        _ => {
            let rows =
                rows.parse::<u32>().ok().filter(|rows| (1..=50).contains(rows)).ok_or_else(
                    || UsageError::new("sidebar section-max-rows takes 1 to 50 or none"),
                )?;
            json!(rows)
        }
    };
    update(section, json!({"max_rows": value}), selectors, flags)
}

fn update(
    section: &str,
    patch: Value,
    selectors: &Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    if section.is_empty() || section.len() > 128 {
        return Err(UsageError::new("a section id must contain 1 to 128 UTF-8 bytes"));
    }
    let mut params = Map::new();
    params.insert("id".into(), Value::String(section.into()));
    params.insert("patch".into(), patch);
    request(Op::SidebarSectionUpdate, selectors, flags, params)
}
