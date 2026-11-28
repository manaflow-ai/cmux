//! Switching backgrounds, the favorite-theme rotation and the title-area
//! contrast: Swift `DisplayBackdropBinding`, `BackdropSwitch`, `BackdropRotation`,
//! `BackdropTimeOfDay`, `ThemeFavoritesSetting`, `TitleAreaContrastSetting`.
//! Every op that depends on the clock takes it: `now` is epoch seconds and the
//! zone is `time_zone` (an IANA name) or `utc_offset` (seconds); the default is UTC.
//!
//! - `backdrop.rotation` `{rotation}` (a string, or minutes as a number) answers
//!   `{rotation}` (its text; absent when invalid). With `now` it adds
//!   `{period, next_turn, wait}`, and with `count` also `{index}` (null for none).
//! - `backdrop.time_of_day` `{entries: {when: picture}, now, location?}` answers
//!   `{valid: false}` or `{valid: true, value, next}`; `valid_values` (the
//!   pictures the app accepts) is checked by `schema::is_backdrop_picture`.
//! - `backdrop.sun` `{location, now}` answers `{altitude, azimuth, dark}`.
//! - `backdrop.sun_events` `{location, now}` answers the day's events (epoch seconds or null).
//! - `backdrop.display_refresh` `{root, display_id, now, paintings}` answers what
//!   the display's background is: `{kind: "inherit" | "none"}`, `{kind: "pin", id}`,
//!   `{kind: "daily", index, wait}` (`paintings` is how many works Shuffle Paintings
//!   turns through) or `{kind: "folder", path, rotation, next_turn, wait}`.
//! - `backdrop.folder_pick` `{rotation, count, now}` answers `{index, next_turn, wait}`.
//! - `theme.favorites` `{root}` answers `{favorites, rotation}`;
//!   `theme.favorite_next` `{current?, favorites}` answers `{next}`;
//!   `theme.favorite_rotated` `{root, today, last_day?}` answers `{next}`;
//!   `theme.day` `{now}` answers `{day}` (`YYYY-MM-DD`, local).
//! - `title_area.contrast` `{root}` answers `{value, diagnostics}`.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::OpError;
use crate::backdrop_switch::{Location, Rotation, TimeOfDay, Zone};
use crate::schema;
use crate::text::ThemeSpec;

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "backdrop.rotation" => rotation(request),
        "backdrop.time_of_day" => time_of_day(request),
        "backdrop.sun" => sun(request),
        "backdrop.sun_events" => sun_events(request),
        "backdrop.display_refresh" => display_refresh(request),
        "backdrop.folder_pick" => folder_pick(request),
        "theme.favorites" => favorites(request),
        "theme.favorite_next" => favorite_next(request),
        "theme.favorite_rotated" => favorite_rotated(request),
        "theme.day" => day(request),
        "title_area.contrast" => title_area_contrast(request),
        _ => return None,
    })
}

fn invalid(what: &str) -> OpError {
    OpError::Invalid(format!("expected {what}"))
}

fn number(request: &Value, key: &str) -> Result<f64, OpError> {
    request.get(key).and_then(Value::as_f64).ok_or_else(|| invalid(&format!("a number `{key}`")))
}

fn zone(request: &Value) -> Result<Zone, OpError> {
    if let Some(name) = request.get("time_zone").and_then(Value::as_str) {
        return name.parse().map(Zone::Named).map_err(|_| invalid("a known `time_zone`"));
    }
    Ok(Zone::Fixed(request.get("utc_offset").and_then(Value::as_i64).unwrap_or(0) as i32))
}

fn at<'a>(root: &'a Value, path: &[&str]) -> Option<&'a Value> {
    path.iter().try_fold(root, |value, key| value.get(*key))
}

/// Swift `BackdropSelectionSetting.rotation`: a choice string or minutes.
fn rotation_of(value: Option<&Value>) -> Option<Rotation> {
    match value? {
        Value::String(text) => Rotation::parse(text),
        other => other.as_f64().and_then(Rotation::from_minutes),
    }
}

fn wait_after(next: f64, now: f64) -> f64 {
    (next - now + 1.0).max(1.0)
}

#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
fn rotation(request: &Value) -> Result<Value, OpError> {
    let Some(rotation) = rotation_of(request.get("rotation")) else { return Ok(json!({})) };
    let mut out = json!({"rotation": rotation.raw()});
    if request.get("now").is_some() {
        let (now, zone) = (number(request, "now")?, zone(request)?);
        let next = rotation.next_turn(now, zone);
        out["period"] = json!(rotation.period(now, zone));
        out["next_turn"] = json!(next);
        out["wait"] = json!(wait_after(next, now));
        if let Some(count) = request.get("count").and_then(Value::as_u64) {
            out["index"] = json!(rotation.index(count as usize, now, zone));
        }
    }
    Ok(out)
}

fn location_of(request: &Value) -> Result<Option<Location>, OpError> {
    match request.get("location") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => {
            Location::parse(text).map(Some).ok_or_else(|| invalid("a `location` \"LAT,LON\""))
        }
        Some(_) => Err(invalid("a string `location`")),
    }
}

fn time_of_day(request: &Value) -> Result<Value, OpError> {
    let members = request
        .get("entries")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid("an object `entries`"))?;
    let mut pairs = Vec::new();
    for (key, value) in members {
        let Some(text) = value.as_str() else { return Ok(json!({"valid": false})) };
        pairs.push((key.as_str(), text));
    }
    pairs.sort();
    let Some(schedule) = TimeOfDay::parse(pairs, schema::is_backdrop_picture) else {
        return Ok(json!({"valid": false}));
    };
    if schedule.entries.is_empty() {
        return Ok(json!({"valid": false}));
    }
    let (now, zone) = (number(request, "now")?, zone(request)?);
    let (value, next) = schedule.resolve(now, location_of(request)?, zone);
    Ok(json!({"valid": true, "value": value, "next": next}))
}

fn sun(request: &Value) -> Result<Value, OpError> {
    let location = location_of(request)?.ok_or_else(|| invalid("a `location`"))?;
    let position = location.sun_position(number(request, "now")?);
    Ok(
        json!({"altitude": position.altitude, "azimuth": position.azimuth, "dark": position.is_dark()}),
    )
}

fn sun_events(request: &Value) -> Result<Value, OpError> {
    let location = location_of(request)?.ok_or_else(|| invalid("a `location`"))?;
    let (now, zone) = (number(request, "now")?, zone(request)?);
    let events = location.sun_events(zone.start_of_day(zone.date_at(now)));
    Ok(json!({"dawn": events.dawn, "sunrise": events.sunrise, "noon": events.noon,
              "sunset": events.sunset, "dusk": events.dusk}))
}

/// Swift `BackdropSelectionSetting.folderPath`.
fn folder_path(raw: &str) -> Option<&str> {
    raw.strip_prefix("folder:").filter(|path| path.starts_with('/') && path.chars().count() > 1)
}

fn display_refresh(request: &Value) -> Result<Value, OpError> {
    let root = request.get("root").ok_or_else(|| invalid("a `root`"))?;
    let id = request.get("display_id").and_then(Value::as_str);
    let raw = id.and_then(|id| at(root, &["appearance", "displayBackgrounds"])?.get(id)?.as_str());
    let (Some(id), Some(raw)) = (id, raw) else { return Ok(json!({"kind": "inherit"})) };
    if raw == "none" {
        return Ok(json!({"kind": "none"}));
    }
    let rotation = rotation_of(
        at(root, &["appearance", "displayBackgroundRotations"]).and_then(|v| v.get(id)),
    )
    .or_else(|| rotation_of(at(root, &["appearance", "backgroundRotation"])))
    .unwrap_or(Rotation::DEFAULT);
    let (now, zone) = (number(request, "now")?, zone(request)?);
    let next = rotation.next_turn(now, zone);
    if let Some(path) = folder_path(raw) {
        return Ok(json!({"kind": "folder", "path": path, "rotation": rotation.raw(),
                         "next_turn": next, "wait": wait_after(next, now)}));
    }
    if raw == "daily" {
        let count = request.get("paintings").and_then(Value::as_u64).unwrap_or(0) as usize;
        return Ok(
            json!({"kind": "daily", "index": rotation.index(count, now, zone), "wait": wait_after(next, now)}),
        );
    }
    if schema::is_backdrop_picture(raw) {
        Ok(json!({"kind": "pin", "id": raw}))
    } else {
        Ok(json!({"kind": "inherit"}))
    }
}

fn folder_pick(request: &Value) -> Result<Value, OpError> {
    let rotation = rotation_of(request.get("rotation")).ok_or_else(|| invalid("a `rotation`"))?;
    let (now, zone) = (number(request, "now")?, zone(request)?);
    let count = request.get("count").and_then(Value::as_u64).unwrap_or(0) as usize;
    let next = rotation.next_turn(now, zone);
    Ok(
        json!({"index": rotation.index(count, now, zone), "next_turn": next, "wait": wait_after(next, now)}),
    )
}

fn rotation_choice(root: &Value) -> &'static str {
    match at(root, &["appearance", "rotateFavoriteThemes"]).and_then(Value::as_str) {
        Some("launch") => "launch",
        Some("daily") => "daily",
        _ => "off",
    }
}

/// The starred themes: names as the pickers write them (no pair, no repeat).
fn favorite_names(root: &Value) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let list = at(root, &["appearance", "favoriteThemes"]).and_then(Value::as_array);
    list.into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter(|name| ThemeSpec::parse(name).is_some_and(|s| s.light == *name && s.dark == *name))
        .filter(|name| seen.insert(*name))
        .map(str::to_string)
        .collect()
}

fn favorites(request: &Value) -> Result<Value, OpError> {
    let root = request.get("root").ok_or_else(|| invalid("a `root`"))?;
    Ok(json!({"favorites": favorite_names(root), "rotation": rotation_choice(root)}))
}

#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
fn next_after(current: Option<&str>, favorites: &[String]) -> Option<String> {
    if favorites.len() < 2 {
        return None;
    }
    match current.and_then(|c| favorites.iter().position(|f| f == c)) {
        Some(index) => Some(favorites[(index + 1) % favorites.len()].clone()),
        None => Some(favorites[0].clone()),
    }
}

fn favorite_next(request: &Value) -> Result<Value, OpError> {
    let list: Vec<String> = request
        .get("favorites")
        .and_then(Value::as_array)
        .ok_or_else(|| invalid("an array `favorites`"))?
        .iter()
        .filter_map(|v| v.as_str().map(str::to_string))
        .collect();
    let current = request.get("current").and_then(Value::as_str);
    Ok(json!({"next": next_after(current, &list)}))
}

fn favorite_rotated(request: &Value) -> Result<Value, OpError> {
    let root = request.get("root").ok_or_else(|| invalid("a `root`"))?;
    let today =
        request.get("today").and_then(Value::as_str).ok_or_else(|| invalid("a string `today`"))?;
    let last_day = request.get("last_day").and_then(Value::as_str);
    match rotation_choice(root) {
        "off" => return Ok(json!({"next": null})),
        "daily" if last_day == Some(today) => return Ok(json!({"next": null})),
        _ => {}
    }
    let current = at(root, &["appearance", "theme"]).and_then(Value::as_str);
    if current
        .and_then(ThemeSpec::parse)
        .is_some_and(|s| s.light != s.dark || current != Some(s.light.as_str()))
    {
        return Ok(json!({"next": null}));
    }
    Ok(json!({"next": next_after(current, &favorite_names(root))}))
}

fn day(request: &Value) -> Result<Value, OpError> {
    let (now, zone) = (number(request, "now")?, zone(request)?);
    Ok(json!({"day": zone.date_at(now).format("%Y-%m-%d").to_string()}))
}

fn title_area_contrast(request: &Value) -> Result<Value, OpError> {
    const PATH: &str = "appearance.titleAreaContrast";
    let root = request.get("root").ok_or_else(|| invalid("a `root`"))?;
    let expected = "expected a number from 0.0 to 2.0";
    let mut diagnostics: Vec<Value> = Vec::new();
    let Some(value) = at(root, &["appearance", "titleAreaContrast"]) else {
        return Ok(json!({"value": 1.0, "diagnostics": diagnostics}));
    };
    let Some(n) = value.as_f64().filter(|n| n.is_finite()) else {
        diagnostics.push(json!({"path": PATH, "message": expected}));
        return Ok(json!({"value": 1.0, "diagnostics": diagnostics}));
    };
    if !(0.0..=2.0).contains(&n) {
        diagnostics.push(json!({"path": PATH, "message": format!("{expected}; clamped")}));
    }
    Ok(json!({"value": n.clamp(0.0, 2.0), "diagnostics": diagnostics}))
}

#[cfg(test)]
#[path = "backdrop_switch_tests.rs"]
mod tests;
