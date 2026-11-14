use super::*;
use crate::cli::cloud_join::{MachineCredential, MachineIdentity};

#[test]
fn local_state_reports_jobs_repo_and_unavailable_capabilities() {
    let result = render(State {
        machine_kind: Some(MachineKind::Local),
        workspace_id: Some("local-workspace".into()),
        repo_root: Some("/work/repo".into()),
        branch: Some("feature/local".into()),
        background_jobs: vec![json!({"id": "job-1", "command": "cargo test", "state": "running"})],
        browser_available: Some(false),
        display_available: Some(false),
        secrets: vec![SecretStatus { name: "API_TOKEN".into(), status: "pending".into() }],
        ..Default::default()
    });

    assert_eq!(result["machine"]["kind"], "local");
    assert_eq!(result["repo"]["branch"], "feature/local");
    assert_eq!(result["backgroundJobs"][0]["id"], "job-1");
    assert_eq!(result["secrets"][0], json!({"name": "API_TOKEN", "status": "pending"}));
    assert_eq!(result["ports"]["available"], false);
    assert!(result["unavailable"].as_array().unwrap().iter().any(|v| v == PORTS_INSTEAD));
}

#[test]
fn cloud_state_includes_preview_and_never_serializes_a_secret_value() {
    let credential = MachineCredential {
        credential: "do-not-leak-secret-value".into(),
        machine_id: "machine-123".into(),
        team_id: "team-123".into(),
        name: "cloud-machine".into(),
        hub_origin: "https://cmux.example".into(),
        last_heartbeat: None,
        revoked: false,
        wg_public_key: "public-key".into(),
        credential_generation: 1,
        user_id: None,
        host_fingerprint: None,
        cloned: false,
        joined_by: None,
        capabilities: None,
        cloned_on: None,
    };
    let identity = MachineIdentity::from_record(&credential);
    let result = render(State {
        machine_kind: Some(MachineKind::Cloud),
        provider: Some("fly".into()),
        machine_id: Some(identity.machine_id),
        machine_name: Some(identity.name),
        team_id: Some(identity.team_id),
        joined: Some(!identity.revoked),
        workspace_id: Some("cloud-workspace".into()),
        repo_root: Some("/workspace/repo".into()),
        branch: Some("main".into()),
        ports: Some(vec![Port { port: 3000, preview_url: Some("https://preview.example".into()) }]),
        preview_urls: Some(vec!["https://preview.example".into()]),
        browser_available: Some(true),
        display_available: Some(true),
        verify_command: Some("just verify".into()),
        secrets: vec![SecretStatus { name: "CLOUD_TOKEN".into(), status: "provided".into() }],
        ..Default::default()
    });
    let serialized = result.to_string();

    assert_eq!(result["machine"]["kind"], "cloud");
    assert_eq!(result["machine"]["provider"], "fly");
    assert_eq!(result["machine"]["name"], "cloud-machine");
    assert_eq!(result["ports"]["listening"][0]["port"], 3000);
    assert_eq!(result["previewUrls"]["urls"][0], "https://preview.example");
    assert_eq!(result["verify"]["command"], "just verify");
    assert!(serialized.contains("CLOUD_TOKEN"));
    assert!(serialized.contains("provided"));
    assert!(!serialized.contains("do-not-leak-secret-value"));
}
