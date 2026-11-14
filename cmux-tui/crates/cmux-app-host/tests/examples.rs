//! The showcase example extensions (`examples/extensions/*/dist/main.js`, built only on
//! cmux-extension-sdk) in the native QuickJS host, the engine cmux runs them in. The bun tests
//! (`js/test/showcase-examples.test.ts`) cover their behavior in depth; these prove the same
//! bundles load and render where JavaScriptCore's extras (Intl, for one) are missing.

mod common;

use cmux_app_host::Limits;
use common::{Harness, example};
use serde_json::{Value, json};

/// Module named `apps` so `verify-cmux-tui-hosted.sh --filter apps::` selects
/// every app platform test in the workspace.
mod apps {
    use super::*;

    fn harness(name: &str, id: &str, settings: Value) -> Harness {
        Harness::with(
            &example(name),
            json!({ "app": { "id": id, "version": "1.0.0" }, "settings": settings }),
            Limits::default(),
        )
    }

    fn has(h: &Harness, mount: &str, want: &str) {
        let texts = h.texts(mount);
        assert!(texts.iter().any(|t| t == want), "{want} missing from {texts:?}");
    }

    fn ok(value: Value) -> (bool, Value) {
        (true, json!({ "value": value }))
    }

    #[test]
    fn weather_reads_open_meteo_and_shows_the_conditions() {
        let mut h = harness(
            "weather",
            "local/showcase-weather",
            json!({ "place": "Lisbon", "units": "celsius" }),
        );
        h.handle("net.fetch", |p, _| {
            let body = if p["url"].as_str().unwrap_or("").contains("geocoding") {
                json!({ "results": [{ "name": "Lisbon", "admin1": "Lisbon", "latitude": 38.7, "longitude": -9.1 }] })
            } else {
                json!({
                    "current": { "temperature_2m": 21.4, "apparent_temperature": 20.6, "weather_code": 0, "wind_speed_10m": 11.8, "is_day": 1 },
                    "daily": { "temperature_2m_max": [24.2], "temperature_2m_min": [15.1] }
                })
            };
            ok(json!({ "status": 200, "body": body.to_string() }))
        });
        assert_eq!(h.mount("m", "renderWeather", json!({})), None);
        has(&h, "m", "21°");
        has(&h, "m", "Clear · feels like 21°");
        has(&h, "m", "High 24° · low 15° · wind 12 km/h");
    }

    #[test]
    fn recent_prs_lists_merged_and_open_pull_requests() {
        let mut h = harness("recent-prs", "local/showcase-recent-prs", json!({}));
        h.handle("integration.request", |p, _| {
            let path = p["path"].as_str().unwrap_or("").to_string();
            let items = if path.contains("author") {
                json!([
                    { "id": 1, "number": 1, "title": "Open one", "html_url": "https://github.com/o/r/pull/1", "draft": false, "state": "open", "repository_url": "https://api.github.com/repos/o/r", "user": { "login": "octo" }, "updated_at": "2026-11-14T08:00:00Z" },
                    { "id": 2, "number": 2, "title": "Merged one", "html_url": "https://github.com/o/r/pull/2", "draft": false, "state": "closed", "pull_request": { "merged_at": "2026-11-14T09:00:00Z" }, "repository_url": "https://api.github.com/repos/o/r", "user": { "login": "octo" }, "updated_at": "2026-11-14T09:00:00Z" }
                ])
            } else {
                json!([])
            };
            ok(json!({ "items": items }))
        });
        assert_eq!(h.mount("m", "renderRecentPRs", json!({})), None);
        has(&h, "m", "Open one");
        has(&h, "m", "Merged one");
        let merged = h
            .find("m", |n| n.kind == "Row" && n.props.get("title") == Some(&json!("Merged one")))
            .expect("row");
        let tree = h.tree("m").1;
        assert_eq!(tree[&merged].props["symbol"], json!("arrow.triangle.merge"));
    }

    #[test]
    fn agent_pet_wakes_when_a_chat_waits() {
        let mut h = harness("agent-pet", "local/showcase-agent-pet", json!({}));
        h.handle("agent.list", |_, _| ok(json!([{ "id": "a1", "state": "working" }])));
        h.handle("agent_chat.list", |_, _| {
            ok(json!({ "chats": [{ "id": "c1", "title": "Fix the build", "state": "input", "unread": true, "harness": "claude", "project": null, "cwd": null, "workspace": null, "machine": null, "updated_ms": 0 }] }))
        });
        assert_eq!(h.mount("m", "renderPet", json!({})), None);
        has(&h, "m", "Byte");
        has(&h, "m", "Fix the build is waiting for you");
    }

    #[test]
    fn agent_standup_groups_recent_chats_by_project() {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_millis() as u64;
        let mut h = harness("agent-standup", "local/showcase-agent-standup", json!({}));
        h.handle("agent_chat.list", move |_, _| {
            ok(json!({ "chats": [
                { "id": "c1", "title": "Ship it", "state": "idle", "unread": false, "harness": "claude", "project": "api", "cwd": null, "workspace": null, "machine": null, "updated_ms": now - 3_600_000 },
                { "id": "c2", "title": "Old", "state": "idle", "unread": false, "harness": "claude", "project": "docs", "cwd": null, "workspace": null, "machine": null, "updated_ms": now - 50 * 3_600_000 }
            ] }))
        });
        assert_eq!(h.mount("m", "renderStandup", json!({})), None);
        has(&h, "m", "api");
        has(&h, "m", "Ship it");
        assert!(!h.texts("m").iter().any(|t| t == "Old"), "{:?}", h.texts("m"));
    }

    #[test]
    fn workspace_notes_adds_a_note_to_the_focused_workspace() {
        let mut h = harness("workspace-notes", "local/showcase-workspace-notes", json!({}));
        h.handle("workspace.list", |_, _| {
            ok(json!([{ "id": "ws_1", "session_id": "s", "name": "api", "index": 0, "focused": true }]))
        });
        h.handle("app.storage.get", |_, _| ok(Value::Null));
        h.handle("app.storage.set", |_, _| ok(Value::Null));
        assert_eq!(h.mount("m", "renderNotes", json!({})), None);
        has(&h, "m", "For api");
        let field = h.find("m", |n| n.kind == "TextField").expect("field");
        h.dispatch("m", &field, "submit", json!({ "text": "Write the README" }));
        has(&h, "m", "Write the README");
        let set = h.calls.iter().find(|c| c.name == "app.storage.set").expect("saved");
        assert_eq!(set.params["key"], json!("notes:ws_1"));
    }
}
