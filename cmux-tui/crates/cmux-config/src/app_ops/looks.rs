//! Densities, backdrops, the omnibar and managed keys: Swift `CustomDensitiesSetting`, `BackdropSelectionSetting`, `BrowserOmnibarSetting`, `ManagedKeyGuard`, `ManagedPreferences`.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value, json};

use super::{OpError, string};
use crate::backdrop_placement::Placement;
use crate::guard;
use crate::managed::{self, ManagedSource};
use crate::schema::{self, Kind, Schema};

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    match op {
        "densities.accepts" => Some(densities_accepts(request)),
        "densities.parse" => Some(densities_parse(request)),
        "densities.json" => Some(densities_json(request)),
        "densities.writes" => Some(densities_writes(request)),
        "densities.unique_id" => Some(densities_unique_id(request)),
        "densities.duplicate" => Some(densities_duplicate(request)),
        "backdrop.accepts" => Some(backdrop_accepts(request)),
        "backdrop.recents" => Some(backdrop_recents(request)),
        "backdrop.previous" => Some(backdrop_previous(request)),
        "backdrop.record_recent" => Some(backdrop_record_recent(request)),
        "backdrop.placement" => Some(backdrop_placement(request)),
        "omnibar.parse" => Some(omnibar_parse(request)),
        "omnibar.search_template" => Some(omnibar_search_template(request)),
        "managed.guard_set" => Some(managed_guard_set(request)),
        "managed.guard_remove" => Some(managed_guard_remove(request)),
        "managed.is_setting_key" => Some(managed_is_setting_key(request)),
        "managed.read" => Some(managed_read(request)),
        _ => None,
    }
}

fn value<'a>(request: &'a Value, key: &str) -> Result<&'a Value, OpError> {
    request.get(key).ok_or_else(|| OpError::Invalid(format!("expected `{key}`")))
}

fn array<'a>(request: &'a Value, key: &str) -> Result<&'a Vec<Value>, OpError> {
    value(request, key)?
        .as_array()
        .ok_or_else(|| OpError::Invalid(format!("expected an array `{key}`")))
}

/// The `id` of a density object, or "".
fn id_of(density: &Value) -> &str {
    density.get("id").and_then(Value::as_str).unwrap_or_default()
}

fn density(value: &Value) -> Option<Value> {
    let members = value.as_object()?;
    let id = members.get("id")?.as_str()?;
    let name = members.get("name")?.as_str()?.trim();
    if !density_id(id) || name.is_empty() {
        return None;
    }
    let number = |key: &str| {
        members
            .get(key)
            .map_or(Some(None), |value| value.as_f64().filter(|x| x.is_finite()).map(Some))
    };
    let level = number("level")?.unwrap_or(0.0).clamp(-1.0, 2.5);
    let spacing = number("spacing")?.unwrap_or(1.0).clamp(0.5, 2.0);
    let font_size = number("fontSize")?.map(|x| x.clamp(9.0, 20.0));
    let tokens = match members.get("tokens") {
        None => None,
        Some(Value::Object(entries)) => {
            let mut result = Map::new();
            for (key, value) in entries {
                let number = value.as_f64().filter(|x| x.is_finite() && *x >= 0.0)?;
                result.insert(key.clone(), json!(number));
            }
            Some(Value::Object(result))
        }
        _ => return None,
    };
    let mut result: Map<String, Value> = [
        ("id".to_owned(), json!(id)),
        ("name".to_owned(), json!(name.chars().take(64).collect::<String>())),
        ("level".to_owned(), json!(level)),
    ]
    .into_iter()
    .collect();
    if let Some(value) = members.get("basedOn").filter(|value| value.is_string()) {
        result.insert("basedOn".to_owned(), value.clone());
    }
    if spacing != 1.0 {
        result.insert("spacing".to_owned(), json!(spacing));
    }
    if let Some(font_size) = font_size {
        result.insert("fontSize".to_owned(), json!(font_size));
    }
    if let Some(tokens) = tokens.filter(|value| value.as_object().is_some_and(|m| !m.is_empty())) {
        result.insert("tokens".to_owned(), tokens);
    }
    Some(Value::Object(result))
}

fn density_id(id: &str) -> bool {
    (1..=64).contains(&id.chars().count())
        && !id.starts_with('-')
        && id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

fn built_in_density(id: &str) -> bool {
    Schema::embedded().row("appearance.density").is_some_and(|row| match &row.kind {
        Kind::Choice(choices) => choices.iter().any(|choice| choice.value == id),
        _ => false,
    })
}

fn densities_accepts(request: &Value) -> Result<Value, OpError> {
    let items = value(request, "value")?
        .as_array()
        .is_some_and(|items| items.iter().all(|item| density(item).is_some()));
    Ok(json!({"valid": items}))
}

fn densities_parse(request: &Value) -> Result<Value, OpError> {
    let Some(root) = value(request, "root")?.as_object() else {
        return Ok(json!({"densities": [], "diagnostics": []}));
    };
    let Some(appearance) = root.get("appearance").and_then(Value::as_object) else {
        return Ok(json!({"densities": [], "diagnostics": []}));
    };
    let Some(raw) = appearance.get("customDensities") else {
        return Ok(json!({"densities": [], "diagnostics": []}));
    };
    let Some(items) = raw.as_array() else {
        return Ok(
            json!({"densities": [], "diagnostics": [{"path": "appearance.customDensities", "message": "expected a list of densities"}]}),
        );
    };
    let mut diagnostics = Vec::new();
    let mut result = Vec::new();
    let mut ids = BTreeSet::new();
    for (index, item) in items.iter().take(64).enumerate() {
        let path = format!("appearance.customDensities[{index}]");
        let Some(item) = density(item) else {
            diagnostics
                .push(json!({"path": path, "message": "expected an object with an id and a name"}));
            continue;
        };
        let id = id_of(&item);
        if built_in_density(id) || !ids.insert(id.to_owned()) {
            diagnostics
                .push(json!({"path": path, "message": format!("the id \"{id}\" is already used")}));
            continue;
        }
        result.push(item);
    }
    Ok(json!({"densities": result, "diagnostics": diagnostics}))
}

fn densities_json(request: &Value) -> Result<Value, OpError> {
    Ok(
        json!({"value": density(value(request, "density")?).ok_or_else(|| OpError::Invalid("invalid density".to_owned()))?}),
    )
}

fn density_list(request: &Value, key: &str) -> Result<Vec<Value>, OpError> {
    array(request, key)?
        .iter()
        .map(|value| density(value).ok_or_else(|| OpError::Invalid("invalid density".to_owned())))
        .collect()
}

fn densities_writes(request: &Value) -> Result<Value, OpError> {
    let active = density(value(request, "active")?)
        .ok_or_else(|| OpError::Invalid("invalid density".to_owned()))?;
    let mut writes = Vec::new();
    if let Some(customs) = request.get("customs") {
        let customs = customs
            .as_array()
            .ok_or_else(|| OpError::Invalid("expected an array `customs`".to_owned()))?;
        let values: Vec<Value> = customs
            .iter()
            .map(|value| {
                density(value).ok_or_else(|| OpError::Invalid("invalid density".to_owned()))
            })
            .collect::<Result<_, _>>()?;
        writes.push(json!({"path": ["appearance", "customDensities"], "value": values}));
    }
    let active_id = active.get("id").cloned().unwrap_or(Value::Null);
    if built_in_density(id_of(&active)) {
        writes.push(json!({"path": ["appearance", "density"], "value": active_id}));
        writes.push(json!({"path": ["appearance", "customDensity"], "value": Value::Null}));
    } else {
        writes.push(json!({"path": ["appearance", "customDensity"], "value": active_id}));
    }
    Ok(json!({"writes": writes}))
}

fn densities_unique_id(request: &Value) -> Result<Value, OpError> {
    let name = string(request, "name")?;
    let existing = density_list(request, "existing")?;
    let mut taken: BTreeSet<String> =
        existing.iter().filter_map(|value| value["id"].as_str().map(str::to_owned)).collect();
    if let Some(row) = Schema::embedded().row("appearance.density")
        && let Kind::Choice(choices) = &row.kind
    {
        taken.extend(choices.iter().map(|choice| choice.value.clone()));
    }
    let slug: String = name
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .split('-')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("-");
    let base: String = slug.chars().take(40).collect::<String>();
    let base = if base.is_empty() { "custom".to_owned() } else { base };
    let id = if !taken.contains(&base) {
        base
    } else {
        (2..).map(|index| format!("{base}-{index}")).find(|id| !taken.contains(id)).unwrap_or(base)
    };
    Ok(json!({"id": id}))
}

fn densities_duplicate(request: &Value) -> Result<Value, OpError> {
    let mut copy = density(value(request, "base")?)
        .ok_or_else(|| OpError::Invalid("invalid density".to_owned()))?;
    let name = string(request, "name")?.to_owned();
    let based_on = built_in_density(id_of(&copy)).then(|| copy.get("id").cloned()).flatten();
    let Some(members) = copy.as_object_mut() else {
        return Err(OpError::Invalid("invalid density".to_owned()));
    };
    members.insert("name".to_owned(), json!(name));
    if let Some(based_on) = based_on {
        members.insert("basedOn".to_owned(), based_on);
    }
    let unique = densities_unique_id(
        &json!({"name": name, "existing": request.get("existing").cloned().unwrap_or_else(|| json!([]))}),
    )?;
    members.insert("id".to_owned(), unique.get("id").cloned().unwrap_or(Value::Null));
    if let Some(font_size) =
        request.get("fontSize").and_then(Value::as_f64).filter(|x| x.is_finite())
    {
        members.insert("fontSize".to_owned(), json!(font_size.clamp(9.0, 20.0)));
    }
    Ok(json!({"value": copy}))
}

fn backdrop_accepts(request: &Value) -> Result<Value, OpError> {
    let kind = string(request, "kind")?;
    let value = value(request, "value")?;
    let valid = match kind {
        "selection" => value.as_str().is_some_and(schema::is_background),
        "picture" => value.as_str().is_some_and(schema::is_backdrop_picture),
        "schedule" => schema::is_backdrop_schedule(value),
        "location" => value.as_str().is_some_and(schema::is_backdrop_location),
        "memory" => schema::is_backdrop_memory(value),
        "recents" => schema::is_backdrop_recents(value),
        "placement" => crate::backdrop_placement::is_placement_map(value),
        _ => return Err(OpError::Invalid(format!("unknown backdrop kind `{kind}`"))),
    };
    Ok(json!({"valid": valid}))
}

fn backdrop_recents(request: &Value) -> Result<Value, OpError> {
    let root = value(request, "root")?;
    let value = root.get("appearance").and_then(|value| value.get("backgroundRecents"));
    let values = schema::recents_of(value)
        .into_iter()
        .filter(|item| schema::is_background(item))
        .collect::<Vec<_>>();
    let mut seen = BTreeSet::new();
    Ok(
        json!({"recents": values.into_iter().filter(|item| seen.insert(item.clone())).collect::<Vec<_>>() }),
    )
}

fn backdrop_previous(request: &Value) -> Result<Value, OpError> {
    let root = value(request, "root")?;
    let current = root
        .get("appearance")
        .and_then(|value| value.get("background"))
        .and_then(Value::as_str)
        .unwrap_or("none");
    let recents = backdrop_recents(request)?
        .get("recents")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let recents = recents.iter().filter_map(Value::as_str).map(str::to_owned).collect::<Vec<_>>();
    Ok(match schema::previous_background(current, &recents) {
        Some(value) => json!({"value": value}),
        None => json!({}),
    })
}

fn backdrop_record_recent(request: &Value) -> Result<Value, OpError> {
    let recents = array(request, "recents")?
        .iter()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect::<Vec<_>>();
    let previous = string(request, "previous")?;
    Ok(json!({"recents": schema::record_recent(&recents, previous)}))
}

fn backdrop_placement(request: &Value) -> Result<Value, OpError> {
    let action = string(request, "action")?;
    match action {
        "accepts" => Ok(
            json!({"valid": crate::backdrop_placement::is_placement_map(value(request, "value")?)}),
        ),
        "parse" => {
            let text = string(request, "text")?;
            Ok(match Placement::parse(text) {
                Some(placement) => json!({"value": placement.to_text()}),
                None => json!({}),
            })
        }
        _ => Err(OpError::Invalid(format!("unknown backdrop placement action `{action}`"))),
    }
}

fn omnibar_parse(request: &Value) -> Result<Value, OpError> {
    let root = value(request, "root")?;
    let schema = Schema::embedded();
    let domains = crate::domains::Domains::default();
    let paths = [
        "browser.searchEngine",
        "browser.customSearchEngine.search",
        "browser.customSearchEngine.suggest",
        "browser.omnibar.remoteSuggestions",
        "browser.omnibar.inlineAutocomplete",
        "browser.omnibar.maxRows",
        "browser.omnibar.calculator",
        "browser.omnibar.showFullURLs",
        "browser.omnibar.glass",
        "browser.omnibar.glassTint",
        "browser.omnibar.glassTintStrength",
        "browser.omnibar.cornerRadius",
        "browser.omnibar.shadow",
        "browser.omnibar.backgroundOpacity",
        "browser.omnibar.height",
        "browser.omnibar.fontSize",
    ];
    let mut values = Map::new();
    let mut invalid = Vec::new();
    let mut clamped = Map::new();
    for key in paths {
        let path = key.split('.').map(str::to_owned).collect::<Vec<_>>();
        let Some(raw) = crate::value::value_at(root, &path) else { continue };
        let Some(row) = schema.row(key) else { continue };
        let mut value = raw.clone();
        if matches!(key, "browser.omnibar.height" | "browser.omnibar.fontSize")
            && let Some(number) = raw.as_f64().filter(|x| x.is_finite())
        {
            let (min, max) = if key.ends_with("height") { (20.0, 56.0) } else { (10.0, 24.0) };
            if !(min..=max).contains(&number) {
                value = json!(number.clamp(min, max));
                clamped.insert(key.to_owned(), value.clone());
            }
        }
        if schema::accepts(row, &value, &domains).is_ok() {
            values.insert(key.to_owned(), value);
        } else {
            invalid.push(key);
        }
    }
    Ok(json!({"values": values, "invalid": invalid, "clamped": clamped}))
}

fn omnibar_search_template(request: &Value) -> Result<Value, OpError> {
    Ok(json!({"valid": value(request, "text")?.as_str().is_some_and(schema::is_search_template)}))
}

fn managed_map(request: &Value) -> Result<BTreeMap<String, ManagedSource>, OpError> {
    let object = value(request, "managed")?
        .as_object()
        .ok_or_else(|| OpError::Invalid("expected an object `managed`".to_owned()))?;
    let mut result = BTreeMap::new();
    for (key, details) in object {
        let source = details.get("source").and_then(Value::as_str).unwrap_or("device");
        result.insert(
            key.clone(),
            match source {
                "team" => ManagedSource::Team(
                    details.get("team").and_then(Value::as_str).unwrap_or_default().to_owned(),
                ),
                _ => ManagedSource::Device,
            },
        );
    }
    Ok(result)
}

fn guard_reply(found: Option<(&str, &ManagedSource)>) -> Value {
    match found {
        Some((key, source)) => {
            json!({"key": key, "source": source.wire_name(), "team": source.team_name()})
        }
        None => json!({}),
    }
}

fn path(request: &Value) -> Result<Vec<String>, OpError> {
    array(request, "path")?
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| OpError::Invalid("expected a string array `path`".to_owned()))
        })
        .collect()
}

fn managed_guard_set(request: &Value) -> Result<Value, OpError> {
    let managed = managed_map(request)?;
    let path = path(request)?;
    let found = managed.iter().find_map(|(key, source)| {
        let managed_path = crate::keypath::key_path(key);
        if path.starts_with(&managed_path) {
            return Some((key.as_str(), source));
        }
        let value = request.get("value")?;
        if managed_path.starts_with(&path)
            && let Some(rest) = managed_path.get(path.len()..)
            && crate::value::value_at(value, rest).is_some()
        {
            return Some((key.as_str(), source));
        }
        None
    });
    Ok(guard_reply(found))
}

fn managed_guard_remove(request: &Value) -> Result<Value, OpError> {
    let managed = managed_map(request)?;
    Ok(guard_reply(guard::managed_key_for_removal(&managed, &path(request)?)))
}

fn managed_is_setting_key(request: &Value) -> Result<Value, OpError> {
    Ok(json!({"valid": managed::is_setting_key(string(request, "key")?)}))
}

fn managed_read(request: &Value) -> Result<Value, OpError> {
    let keys = request
        .get("keys")
        .and_then(Value::as_array)
        .map(|keys| keys.iter().filter_map(Value::as_str).collect::<Vec<_>>());
    let values = if let Some(keys) = keys {
        managed::read_keys(&keys, |name| std::env::var(name).ok())
    } else {
        managed::default_reader(|name| std::env::var(name).ok()).read()
    };
    Ok(json!({"forced": values.forced, "recommended": values.recommended}))
}

#[cfg(test)]
#[path = "looks_tests.rs"]
mod tests;
