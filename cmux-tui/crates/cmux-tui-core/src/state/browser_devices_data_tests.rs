//! The built-in device list (`data/emulated-devices.json`) as
//! `browser.devices.list` serves it: every row is valid (none is dropped
//! silently), titles are unique, phones, tablets and foldables carry a user
//! agent, and every row has the menu fields the app groups and sorts by
//! (`group`, `brand`, `released`). Also pins the coverage asked for in
//! u2406 (old and new iPhones, Pixels, Galaxies, folds, Macs, displays).

use std::collections::HashSet;

use rusqlite::Connection;
use serde_json::Value;

use super::browser_devices::{create_schema, list};

const DATA: &str = include_str!("../../data/emulated-devices.json");
const GROUPS: [&str; 6] = ["phone", "foldable", "tablet", "laptop", "desktop", "smart-display"];

fn served() -> Vec<Value> {
    let mut connection = Connection::open_in_memory().unwrap();
    let transaction = connection.transaction().unwrap();
    create_schema(&transaction).unwrap();
    transaction.commit().unwrap();
    list(&connection).unwrap()["devices"].as_array().unwrap().clone()
}

fn title(device: &Value) -> &str {
    device["title"].as_str().unwrap_or_default()
}

#[test]
fn every_built_in_device_is_served() {
    let file: Value = serde_json::from_str(DATA).unwrap();
    let in_file = file["devices"].as_array().unwrap().len();
    assert_eq!(served().len(), in_file, "a row of the data file fails the daemon's check");
}

#[test]
fn titles_are_unique_ignoring_case_and_punctuation() {
    let mut seen = HashSet::new();
    for device in served() {
        let key: String = title(&device)
            .chars()
            .filter(|c| c.is_alphanumeric() || *c == '+')
            .flat_map(char::to_lowercase)
            .collect();
        assert!(seen.insert(key), "duplicate title {:?}", title(&device));
    }
}

#[test]
fn sizes_ratios_and_user_agents_are_sane() {
    for device in served() {
        let name = title(&device);
        let screen = &device["screen"];
        let ratio = screen["device-pixel-ratio"].as_f64().unwrap();
        assert!((1.0..=4.0).contains(&ratio), "{name}: device-pixel-ratio {ratio}");
        for side in ["vertical", "horizontal"] {
            let (w, h) = (screen[side]["width"].as_i64().unwrap(), screen[side]["height"].as_i64().unwrap());
            assert!(w > 0 && h > 0, "{name}: {side} {w}x{h}");
        }
        let group = device["group"].as_str().unwrap_or_default();
        if matches!(group, "phone" | "foldable" | "tablet") {
            let agent = device["user-agent"].as_str().unwrap_or_default();
            assert!(!agent.is_empty(), "{name}: a {group} needs a user agent");
            let caps = device["capabilities"].as_array().cloned().unwrap_or_default();
            assert!(caps.contains(&Value::from("touch")), "{name}: a {group} is a touch device");
        }
    }
}

#[test]
fn every_device_has_a_group_a_brand_and_a_release_month() {
    for device in served() {
        let name = title(&device);
        let group = device["group"].as_str().unwrap_or_default();
        assert!(GROUPS.contains(&group), "{name}: group {group:?}");
        assert!(!device["brand"].as_str().unwrap_or_default().is_empty(), "{name}: no brand");
        let released = device["released"].as_str().unwrap_or_default();
        let ok = released.len() == 7
            && released[..4].parse::<u32>().is_ok_and(|y| (2010..=2030).contains(&y))
            && &released[4..5] == "-"
            && released[5..].parse::<u32>().is_ok_and(|m| (1..=12).contains(&m));
        assert!(ok, "{name}: released {released:?} is not YYYY-MM");
    }
}

#[test]
fn cmux_devices_cite_sources_and_rumored_ones_stay_hidden() {
    for device in served().iter().filter(|d| d["origin"] == "cmux") {
        let name = title(device);
        let sources = device["sources"].as_array().cloned().unwrap_or_default();
        assert!(!sources.is_empty(), "{name}: no sources");
        if device["rumored"] == true {
            assert_eq!(device["show-by-default"], false, "{name}: a rumored device is hidden by default");
        }
    }
}

#[test]
fn the_list_covers_old_and_new_phones_computers_and_displays() {
    let devices = served();
    let titles: HashSet<&str> = devices.iter().map(title).collect();
    for wanted in [
        "iPhone 8",
        "iPhone X",
        "iPhone 11",
        "iPhone 12",
        "iPhone 12 mini",
        "iPhone 12 Pro Max",
        "iPhone 13",
        "iPhone 13 mini",
        "iPhone 13 Pro Max",
        "iPhone 17",
        "iPhone Air",
        "iPhone 18",
        "Pixel 6",
        "Pixel 6 Pro",
        "Pixel 6a",
        "Pixel 7 Pro",
        "Pixel 9a",
        "Pixel Fold",
        "Pixel 10 Pro Fold",
        "Pixel Tablet",
        "Galaxy S21",
        "Galaxy S22 Ultra",
        "Galaxy S23",
        "Galaxy S24 Ultra",
        "Galaxy S24 FE",
        "Galaxy A15",
        "Galaxy A25",
        "Galaxy A35",
        "Galaxy A56",
        "Galaxy Z Fold 3",
        "Galaxy Z Fold 7",
        "Galaxy Z Flip 3",
        "Galaxy Z Flip 6",
        "Galaxy Tab S9",
        "OnePlus 13",
        "iPad (10th gen)",
        "iPad Pro 12.9 (6th gen)",
        "Surface Pro 11",
        "MacBook Air 13\"",
        "MacBook Air 15\"",
        "MacBook Pro 14\"",
        "MacBook Pro 16\"",
        "MacBook Pro 13\" (2020)",
        "iMac 24\"",
        "Studio Display",
        "Pro Display XDR",
        "Desktop 1080p",
        "Desktop 1440p",
        "Desktop 4K",
        "Nest Hub",
    ] {
        assert!(titles.contains(wanted), "{wanted} missing");
    }
    let count = |group: &str| devices.iter().filter(|d| d["group"] == group).count();
    assert!(count("phone") >= 80, "phones: {}", count("phone"));
    assert!(count("foldable") >= 12, "foldables: {}", count("foldable"));
    assert!(count("laptop") >= 8, "laptops: {}", count("laptop"));
    assert!(count("desktop") >= 6, "desktops: {}", count("desktop"));
}

#[test]
fn chrome_rows_stay_verbatim_and_first() {
    let devices = served();
    assert_eq!(title(&devices[0]), "iPhone SE");
    assert_eq!(devices.iter().filter(|d| d["origin"] == "chrome").count(), 46);
    // Chrome's own menu section is still served next to the finer group.
    let find = |t: &str| devices.iter().find(|d| title(d) == t).unwrap().clone();
    assert_eq!(find("Nest Hub Max")["category"], "smart-display");
    assert_eq!(find("Galaxy Tab S4")["group"], "tablet");
    assert_eq!(find("Surface Duo")["group"], "foldable");
    assert_eq!(find("Laptop with HiDPI screen")["group"], "laptop");
    assert_eq!(find("iPhone 16")["brand"], "Apple");
    assert_eq!(find("Pixel 9")["brand"], "Google");
    assert_eq!(find("Samsung Galaxy A55")["brand"], "Samsung");
}
