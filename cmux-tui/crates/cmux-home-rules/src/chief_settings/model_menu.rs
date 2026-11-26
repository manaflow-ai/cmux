//! The Chief's Model popup below its "Default" item (`HomeChiefModelMenu.swift`), built from the
//! models acpmux offers for the harness (plans/cmux-next/model-catalog.md):
//!
//! - Recent picks on this harness first (not the current one).
//! - One section per family, in the harness's order, holding its newest release; each model's context
//!   variant ("Opus 5.5 · 1M context") right after it.
//! - Plan-and-execute combinations (Claude Code's `opusplan`), then models of no family.
//! - Older releases last, newest first.
//!
//! An alias the harness reports for a release (`opus` → Claude Opus 5.5) takes that release's row, unless
//! the Chief is set on the release id itself. A chosen model the harness does not offer still shows. A list
//! with no families (a hosted Chief's) has no headers.

use super::names::model_name;
use super::{Strings, format, strings, trim};
use crate::ops::{self, OpError};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// One model acpmux offers (`ChiefEngineReport.Model`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Model {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub family: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub short_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub efforts: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fast: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub aliases: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolved_model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_window: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub release_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

impl Model {
    fn has_alias(&self, base: &str) -> bool {
        self.aliases.as_ref().is_some_and(|aliases| aliases.iter().any(|alias| alias == base))
    }
}

/// One model row: the value a pick writes, the title it shows and its tooltip.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub value: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// A popup entry: a section header or a model row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Entry {
    Header { title: String },
    Model(Item),
}

/// The popup.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Menu {
    pub entries: Vec<Entry>,
    /// Every model row, in order (a recent model also shows in its own section).
    pub items: Vec<Item>,
}

/// `id` without a context-window suffix (`opus[1m]` → `opus`).
pub fn base_id(id: &str) -> &str {
    if !id.ends_with(']') {
        return id;
    }
    match id.rfind('[') {
        Some(open) => id.get(..open).unwrap_or(id),
        None => id,
    }
}

/// The release `id` runs: its own metadata row, or the release an alias (or a context variant of either)
/// names.
pub fn release_of<'a>(id: &str, models: &'a [Model]) -> Option<&'a Model> {
    let base = base_id(id);
    if let Some(own) = models.iter().find(|model| model.id == base && model.family.is_some()) {
        return Some(own);
    }
    let target = models
        .iter()
        .find(|model| model.id == base)
        .and_then(|model| model.resolved_model.clone())
        .unwrap_or_else(|| base.to_owned());
    models
        .iter()
        .find(|model| model.family.is_some() && (model.id == target || model.has_alias(base)))
        .or_else(|| models.iter().find(|model| model.id == base))
}

/// The name a person reads for model `id`: the catalog's name for the release it runs (with its context
/// variant), else acpmux's name, else the id made readable.
pub fn display_name_of(id: &str, models: &[Model], strings: &Strings) -> String {
    if let Some(release) = release_of(id, models)
        && release.family.is_some()
    {
        let name = display_name(release);
        return if base_id(id) == id { name } else { variant_title(&name, id, strings) };
    }
    if let Some(own) = models.iter().find(|model| model.id == id) {
        return readable(own);
    }
    model_name(id)
}

/// `model`'s own name, or its id made readable when acpmux named it by its id.
pub fn readable(model: &Model) -> String {
    let name = trim(&model.name);
    if name.is_empty() || name == model.id { model_name(&model.id) } else { name.to_owned() }
}

fn display_name(model: &Model) -> String {
    model.short_name.clone().unwrap_or_else(|| model.name.clone())
}

/// "Opus 5.5 · 1M context" for `[1m]`; another suffix shows as the harness wrote it.
fn variant_title(base: &str, id: &str, strings: &Strings) -> String {
    let start = id.rfind('[').map_or(0, |open| open + 1);
    let mut suffix: String = id.get(start..).unwrap_or_default().to_owned();
    suffix.pop();
    let suffix = suffix.to_lowercase();
    let context =
        if suffix.ends_with('m') || suffix.ends_with('k') { suffix.to_uppercase() } else { suffix };
    format(&strings.context_variant_format, &[base, &context])
}

fn plan_title(model: &Model, strings: &Strings) -> String {
    if model.id == "opusplan" { strings.opus_plan_title.clone() } else { readable(model) }
}

fn plan_detail(model: &Model, title: &str) -> Option<String> {
    let mut lines: Vec<String> = Vec::new();
    for line in [trim(&model.name).to_owned(), model.id.clone()] {
        if !line.is_empty() && line != title && !lines.contains(&line) {
            lines.push(line);
        }
    }
    if lines.is_empty() { None } else { Some(lines.join("\n")) }
}

fn is_alias(model: &Model, models: &[Model]) -> bool {
    let base = base_id(&model.id);
    model.family.is_none()
        && (model.resolved_model.is_some() || models.iter().any(|other| other.has_alias(base)))
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Model,
    Plan,
}

#[derive(Clone)]
struct Row {
    item: Item,
    family: Option<String>,
    release: Option<String>,
    kind: Kind,
    key: String,
    variant: bool,
    description: Option<String>,
}

fn rows(models: &[Model], chosen: Option<&str>, strings: &Strings) -> Vec<Row> {
    let mut rows: Vec<Row> = Vec::new();
    let mut seen: BTreeMap<String, usize> = BTreeMap::new();
    for model in models.iter().filter(|model| model.id != "default") {
        let release = release_of(&model.id, models);
        let release_family = release.and_then(|release| release.family.clone());
        let is_plan = model.family.is_none()
            && release_family.is_none()
            && model.id.to_lowercase().ends_with("plan");
        let base = base_id(&model.id);
        let variant = base != model.id;
        let key_base = if release_family.is_some() {
            release.map(|release| release.id.as_str())
        } else {
            None
        }
        .unwrap_or(base);
        let key = format!("{key_base}{}", model.id.get(base.len()..).unwrap_or_default());
        let mut title = if is_plan {
            plan_title(model, strings)
        } else if release_family.is_some() {
            release.map(display_name).unwrap_or_else(|| readable(model))
        } else {
            readable(model)
        };
        if variant {
            title = variant_title(&title, &model.id, strings);
        }
        let detail = if is_plan { plan_detail(model, &title) } else { None };
        let row = Row {
            item: Item { value: model.id.clone(), title, detail },
            family: release_family,
            release: release.and_then(|release| release.release_date.clone()),
            kind: if is_plan { Kind::Plan } else { Kind::Model },
            key: key.clone(),
            variant,
            description: model
                .description
                .clone()
                .or_else(|| release.and_then(|release| release.description.clone())),
        };
        if let Some(&index) = seen.get(&key) {
            let keeps_new = Some(model.id.as_str()) == chosen
                || (rows.get(index).map(|row| row.item.value.as_str()) != chosen
                    && is_alias(model, models));
            if keeps_new && let Some(row) = rows.get_mut(index) {
                row.item.value = model.id.clone();
            }
            continue;
        }
        seen.insert(key, rows.len());
        rows.push(row);
    }
    if let Some(chosen) = chosen
        && chosen != "default"
        && !rows.iter().any(|row| row.item.value == chosen)
    {
        rows.push(Row {
            item: Item { value: chosen.to_owned(), title: model_name(chosen), detail: None },
            family: None,
            release: None,
            kind: Kind::Model,
            key: chosen.to_owned(),
            variant: false,
            description: None,
        });
    }
    for row in rows.iter_mut().filter(|row| row.kind == Kind::Model) {
        let id = if row.item.title == row.item.value { None } else { Some(row.item.value.clone()) };
        let lines: Vec<String> = [row.description.clone(), id].into_iter().flatten().collect();
        row.item.detail = if lines.is_empty() { None } else { Some(lines.join("\n")) };
    }
    rows
}

fn with_variants(rows: &[Row]) -> Vec<Row> {
    let mut ordered: Vec<Row> = Vec::new();
    for row in rows.iter().filter(|row| !row.variant) {
        ordered.push(row.clone());
        ordered.extend(
            rows.iter().filter(|other| other.variant && base_id(&other.key) == row.key).cloned(),
        );
    }
    let rest: Vec<Row> = rows
        .iter()
        .filter(|row| {
            row.variant && !ordered.iter().any(|placed| placed.item.value == row.item.value)
        })
        .cloned()
        .collect();
    ordered.extend(rest);
    ordered
}

/// The popup for `models` (acpmux's, in its order), the chosen model (nil: Default) and this harness's
/// recent picks, newest first.
pub fn menu(models: &[Model], chosen: Option<&str>, recents: &[String], strings: &Strings) -> Menu {
    let rows = rows(models, chosen, strings);
    let mut entries: Vec<Entry> = Vec::new();
    let header = |title: &str| Entry::Header { title: title.to_owned() };
    let recent_rows: Vec<&Row> = recents
        .iter()
        .filter(|value| Some(value.as_str()) != chosen)
        .filter_map(|value| rows.iter().find(|row| &row.item.value == value))
        .take(3)
        .collect();
    if !recent_rows.is_empty() {
        entries.push(header(&strings.recent_section));
        entries.extend(recent_rows.iter().map(|row| Entry::Model(row.item.clone())));
    }
    let headed = rows.iter().any(|row| row.family.is_some());
    let mut newest: BTreeMap<String, String> = BTreeMap::new();
    for row in &rows {
        if let (Some(family), Some(release)) = (&row.family, &row.release) {
            let top = newest.entry(family.clone()).or_insert_with(|| release.clone());
            if release > top {
                *top = release.clone();
            }
        }
    }
    let is_older = |row: &Row| match (&row.family, &row.release) {
        (Some(family), Some(release)) => newest.get(family).is_some_and(|top| release < top),
        _ => false,
    };
    let mut families: Vec<String> = Vec::new();
    for row in &rows {
        if let Some(family) = &row.family
            && !families.contains(family)
        {
            families.push(family.clone());
        }
    }
    for family in &families {
        let members: Vec<Row> = rows
            .iter()
            .filter(|row| row.family.as_ref() == Some(family) && !is_older(row))
            .cloned()
            .collect();
        if members.is_empty() {
            continue;
        }
        entries.push(header(family));
        entries.extend(with_variants(&members).into_iter().map(|row| Entry::Model(row.item)));
    }
    let plans: Vec<&Row> = rows.iter().filter(|row| row.kind == Kind::Plan).collect();
    if !plans.is_empty() {
        if headed {
            entries.push(header(&strings.plan_and_execute_section));
        }
        entries.extend(plans.iter().map(|row| Entry::Model(row.item.clone())));
    }
    let others: Vec<&Row> =
        rows.iter().filter(|row| row.family.is_none() && row.kind == Kind::Model).collect();
    if !others.is_empty() {
        if headed {
            entries.push(header(&strings.other_models_section));
        }
        entries.extend(others.iter().map(|row| Entry::Model(row.item.clone())));
    }
    let mut older: Vec<Row> = rows.iter().filter(|row| is_older(row)).cloned().collect();
    older.sort_by(|a, b| b.release.cmp(&a.release));
    if !older.is_empty() {
        entries.push(header(&strings.older_models_section));
        entries.extend(with_variants(&older).into_iter().map(|row| Entry::Model(row.item)));
    }
    let items = entries
        .iter()
        .filter_map(|entry| match entry {
            Entry::Model(item) => Some(item.clone()),
            Entry::Header { .. } => None,
        })
        .collect();
    Menu { entries, items }
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct MenuRequest {
    models: Vec<Model>,
    chosen: Option<String>,
    recents: Vec<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct IdRequest {
    id: String,
    models: Vec<Model>,
}

fn object(request: &Value) -> Value {
    if request.is_null() { Value::Object(Default::default()) } else { request.clone() }
}

pub(super) fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    let words = strings(request);
    let request = &object(request);
    match name {
        "modelMenu" => {
            let request: MenuRequest = ops::parse(request)?;
            ops::reply(&menu(&request.models, request.chosen.as_deref(), &request.recents, &words))
        }
        "modelRelease" => {
            let request: IdRequest = ops::parse(request)?;
            ops::reply(&release_of(&request.id, &request.models))
        }
        "modelDisplayName" => {
            let request: IdRequest = ops::parse(request)?;
            ops::reply(&display_name_of(&request.id, &request.models, &words))
        }
        _ => Err(OpError::Unknown),
    }
}
