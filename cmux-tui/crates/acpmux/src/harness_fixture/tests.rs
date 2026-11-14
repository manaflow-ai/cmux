use super::*;
use crate::harness_health::{HealthService, Settings};
use serde_json::json;

fn fixture() -> Fixture {
    serde_json::from_value(json!({
            "harnesses": {"codex": {"argv": ["codex-acp"], "description": "found on PATH"}},
            "health": [{
                "id": "codex", "program": "codex-acp", "path": "/opt/fixture/bin/codex-acp",
                "channel": "npm", "package": "@zed-industries/codex-acp",
                "version": "0.9.0", "latest": "0.10.0", "latestCheckedAt": 1, "outdated": true,
                "auth": "signedIn", "authDetail": null, "login": "codex login",
                "update": {"argv": ["/bin/false"], "command": "npm install -g @zed-industries/codex-acp@latest", "elevated": false},
                "problem": null, "checkedAt": 1
            }]
        }))
        .unwrap()
}

#[test]
fn a_fixture_file_parses_and_refuses_unknown_fields() {
    let dir = std::env::temp_dir().join(format!("amx-harness-fixture-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("fixture.json");
    std::fs::write(&file, serde_json::to_vec(&json!({"harnesses": {}, "health": []})).unwrap())
        .unwrap();
    assert_eq!(Fixture::read(&file).unwrap(), Fixture::default());
    std::fs::write(&file, br#"{"harness": {}}"#).unwrap();
    assert!(Fixture::read(&file).unwrap_err().contains("not a harness fixture"));
    assert!(Fixture::read(&dir.join("missing.json")).unwrap_err().contains("cannot read"));
    #[cfg(unix)]
    {
        let link = dir.join("link.json");
        let _ = std::fs::remove_file(&link);
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert!(Fixture::read(&link).unwrap_err().contains("cannot read"), "a link was followed");
        // O_NONBLOCK: a FIFO opens without a writer, then the type check refuses it.
        assert!(Fixture::read(&dir).unwrap_err().contains("not a regular file"));
        assert!(Fixture::read(Path::new("/dev/zero")).unwrap_err().contains("not a regular file"));
        std::fs::write(&file, vec![b' '; MAX_BYTES as usize + 1]).unwrap();
        assert!(Fixture::read(&file).unwrap_err().contains("over"));
    }
    let _ = std::fs::remove_dir_all(dir);
}

/// The fixture's rows are the check, whatever the subjects; no update runs.
#[tokio::test]
async fn a_fixture_service_serves_its_rows_and_runs_no_update() {
    let fixture = fixture();
    let service = HealthService::new();
    service.attach(Settings { fixture: Some(fixture.health.clone()), ..Settings::default() });
    assert_eq!(service.rows(), fixture.health);
    let subject = crate::harness_health::Subject {
        id: "other".into(),
        program: "/nonexistent/other".into(),
        family: "other".into(),
        check: vec![],
        env: Default::default(),
        login: None,
        unresolved: vec![],
        probe_error: None,
    };
    assert_eq!(service.check(vec![subject], true).await, fixture.health);
    assert!(service.run_auto_updates().await.is_empty());
    let (rows, ran) = service.run_updates(async { vec![] }, None).await;
    assert_eq!(rows, fixture.health);
    assert_eq!(ran.len(), 1);
    assert!(
        matches!(&ran[0].1, crate::harness_health::auto::Requested::Refused(why) if why == REFUSAL)
    );
    assert!(service.cached_update_plan("codex").is_err());
    assert!(service.prepare_update("codex").is_err());
    assert!(fixture.names("codex") && !fixture.names("claude"));
}

/// The catalog takes the fixture's harnesses instead of discovery.
#[test]
fn a_fixture_catalog_joins_only_its_harnesses() {
    let mut cfg = crate::config::Config::default();
    cfg.join_fixture(&fixture());
    assert_eq!(cfg.harnesses.keys().collect::<Vec<_>>(), ["codex"]);
    assert!(cfg.discovered.contains("codex"));
    assert_eq!(cfg.default_harness.as_deref(), Some("codex"));
}
