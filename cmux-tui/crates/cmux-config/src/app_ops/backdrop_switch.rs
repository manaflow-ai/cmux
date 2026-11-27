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
mod tests {
    use super::*;

    fn run(op: &str, request: Value) -> Value {
        call(op, &request).unwrap().unwrap()
    }

    #[test]
    fn rotation_op_parses_and_turns() {
        assert_eq!(run("backdrop.rotation", json!({"rotation": "bogus"})), json!({}));
        assert_eq!(run("backdrop.rotation", json!({"rotation": 30.4}))["rotation"], "30");
        let out = run(
            "backdrop.rotation",
            json!({"rotation": "hourly", "now": 3_600.0 * 5.0 + 10.0, "count": 4}),
        );
        assert_eq!(out["next_turn"], json!(3_600.0 * 6.0));
        assert_eq!(out["wait"], json!(3_600.0 - 10.0 + 1.0));
        assert_eq!(out["period"], 5);
    }

    #[test]
    fn display_refresh_follows_the_swift_binding() {
        let root = json!({"appearance": {
            "displayBackgrounds": {"a": "none", "b": "daily", "c": "folder:/pics", "d": "file:/x.png", "e": "folder:rel"},
            "displayBackgroundRotations": {"c": "15m"}, "backgroundRotation": "hourly"}});
        let go = |id: &str| {
            run(
                "backdrop.display_refresh",
                json!({"root": root, "display_id": id, "now": 1_000.0, "paintings": 150}),
            )
        };
        assert_eq!(go("a")["kind"], "none");
        assert_eq!(go("zz")["kind"], "inherit");
        assert_eq!(go("e")["kind"], "inherit");
        assert_eq!(go("d"), json!({"kind": "pin", "id": "file:/x.png"}));
        let daily = go("b");
        assert_eq!(daily["kind"], "daily");
        assert!(daily["index"].is_u64());
        let folder = go("c");
        assert_eq!(
            (folder["rotation"].as_str(), folder["next_turn"].as_f64()),
            (Some("15m"), Some(1_800.0))
        );
        assert_eq!(folder["path"], "/pics");
        // Without a display id the display inherits.
        assert_eq!(
            run("backdrop.display_refresh", json!({"root": root, "now": 0.0}))["kind"],
            "inherit"
        );
    }

    #[test]
    fn time_of_day_op_resolves() {
        let out = run("backdrop.time_of_day", json!({"entries": {"07:00": "daily"}, "now": 0.0}));
        assert_eq!(out["valid"], false);
        let out = run(
            "backdrop.time_of_day",
            json!({"entries": {"07:00": "desktop", "19:00": "system:/a.heic"},
            "now": 8.0 * 3_600.0}),
        );
        assert_eq!(out["value"], "desktop");
        assert_eq!(out["next"], json!(19.0 * 3_600.0));
        assert_eq!(
            run("backdrop.time_of_day", json!({"entries": {"7": "desktop"}, "now": 0.0}))["valid"],
            false
        );
    }

    #[test]
    fn favorites_port_the_swift_tests() {
        let root = |theme: Option<&str>, rotate: Option<&str>| {
            let mut appearance = json!({"favoriteThemes": ["Nord", "Dracula", "Nord", 1, "light:A,dark:B", " ", "Rose Pine"]});
            if let Some(t) = theme {
                appearance["theme"] = json!(t);
            }
            if let Some(r) = rotate {
                appearance["rotateFavoriteThemes"] = json!(r);
            }
            json!({"appearance": appearance})
        };
        let out = run("theme.favorites", json!({"root": root(None, None)}));
        assert_eq!(out["favorites"], json!(["Nord", "Dracula", "Rose Pine"]));
        assert_eq!(run("theme.favorites", json!({"root": {}}))["favorites"], json!([]));
        let next = |current: Option<&str>, list: Value| {
            run("theme.favorite_next", json!({"current": current, "favorites": list}))["next"]
                .clone()
        };
        let three = json!(["Nord", "Dracula", "Rose Pine"]);
        assert_eq!(next(Some("Nord"), three.clone()), "Dracula");
        assert_eq!(next(Some("Rose Pine"), three.clone()), "Nord");
        assert_eq!(next(Some("Tokyo Night"), three.clone()), "Nord");
        assert_eq!(next(None, three), "Nord");
        assert_eq!(next(Some("Nord"), json!(["Nord"])), Value::Null);
        let rotated = |root: Value, today: &str, last: Option<&str>| {
            run("theme.favorite_rotated", json!({"root": root, "today": today, "last_day": last}))["next"].clone()
        };
        let two = |theme: &str, rotate: &str| json!({"appearance": {"favoriteThemes": ["Nord", "Dracula"], "theme": theme, "rotateFavoriteThemes": rotate}});
        assert_eq!(rotated(root(Some("Nord"), None), "2026-10-20", None), Value::Null);
        assert_eq!(rotated(root(Some("Nord"), Some("bogus")), "2026-10-20", None), Value::Null);
        assert_eq!(rotated(two("Nord", "launch"), "2026-10-20", Some("2026-10-20")), "Dracula");
        assert_eq!(rotated(two("Dracula", "daily"), "2026-10-20", Some("2026-10-20")), Value::Null);
        assert_eq!(rotated(two("Dracula", "daily"), "2026-10-21", Some("2026-10-20")), "Nord");
        assert_eq!(rotated(two("Dracula", "daily"), "2026-10-21", None), "Nord");
        for spec in ["light:Rose Pine Dawn,dark:Rose Pine", "light:Nord,dark:Nord", "dark:Nord"] {
            assert_eq!(rotated(two(spec, "launch"), "2026-10-20", None), Value::Null, "{spec}");
        }
        assert_eq!(run("theme.day", json!({"now": 1_792_454_400.0}))["day"], "2026-10-20");
    }

    #[test]
    fn title_area_contrast_clamps() {
        let go = |v: Value| {
            run("title_area.contrast", json!({"root": {"appearance": {"titleAreaContrast": v}}}))
        };
        assert_eq!(go(json!(1.5))["value"], 1.5);
        let high = go(json!(3));
        assert_eq!(high["value"], 2.0);
        assert!(high["diagnostics"][0]["message"].as_str().unwrap().ends_with("; clamped"));
        assert_eq!(go(json!("x"))["value"], 1.0);
        assert_eq!(run("title_area.contrast", json!({"root": {}}))["value"], 1.0);
    }
}
