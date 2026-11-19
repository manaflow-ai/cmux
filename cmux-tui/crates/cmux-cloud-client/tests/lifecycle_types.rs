//! Compile API clients as a downstream crate: method availability and moves
//! must be enforced outside the implementation module, not by source matching.
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    time::SystemTime,
};

fn library(deps: &Path, name: &str) -> PathBuf {
    let prefix = format!("lib{name}-");
    fs::read_dir(deps)
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| {
            let filename = entry.file_name();
            let filename = filename.to_string_lossy();
            filename.starts_with(&prefix) && filename.ends_with(".rlib")
        })
        .max_by_key(|entry| entry.metadata().unwrap().modified().unwrap())
        .unwrap_or_else(|| panic!("missing compiled {name} in {}", deps.display()))
        .path()
}

#[test]
fn lifecycle_capabilities_reject_invalid_operations_and_reuse() {
    let deps = std::env::current_exe().unwrap().parent().unwrap().to_path_buf();
    let client = library(&deps, "cmux_cloud_client");
    let lifeline = library(&deps, "cmux_lifeline");
    let nonce = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos();
    let out =
        std::env::temp_dir().join(format!("cmux-lifecycle-types-{}-{nonce}", std::process::id()));
    fs::create_dir(&out).unwrap();
    let cases = [
        (
            "relay_claimed_delete",
            "fn check(p: Capability<Claimed>) { p.prepare_delete(\"key\"); }",
            Some("E0599"),
        ),
        (
            "relay_request_consumed",
            "fn check(r: cmux_cloud_client::lifecycle::relay::Request) { let _ = r.complete(Default::default(), \"8\".into()); let _ = r.complete(Default::default(), \"8\".into()); }",
            Some("E0382"),
        ),
        (
            "relay_valid",
            "fn check(r: Capability<Running>, p: Capability<Paused>) { let _ = r.prepare_pause(\"key\"); let _ = p.prepare_resume(\"key\"); }",
            None,
        ),
        (
            "relay_paused_pause",
            "fn check(p: Capability<Paused>) { p.prepare_pause(\"key\"); }",
            Some("E0599"),
        ),
        (
            "relay_unknown_resume",
            "fn check(u: Capability<Unknown>) { u.prepare_resume(\"key\"); }",
            Some("E0599"),
        ),
        (
            "relay_consumed",
            "fn check(r: Capability<Running>) { let _ = r.prepare_pause(\"key\"); r.prepare_delete(\"other\"); }",
            Some("E0382"),
        ),
        (
            "valid",
            "async fn check(r: Capability<Running>, p: Capability<Paused>, c: &LifecycleClient) { let _ = r.pause(c, \"key\").await; let _ = p.resume(c, \"key\").await; }",
            None,
        ),
        (
            "paused_pause",
            "async fn check(p: Capability<Paused>, c: &LifecycleClient) { p.pause(c, \"key\").await; }",
            Some("E0599"),
        ),
        (
            "running_resume",
            "async fn check(r: Capability<Running>, c: &LifecycleClient) { r.resume(c, \"key\").await; }",
            Some("E0599"),
        ),
        (
            "deleted_delete",
            "async fn check(d: Capability<Deleted>, c: &LifecycleClient) { d.delete(c, \"key\").await; }",
            Some("E0599"),
        ),
        (
            "unknown_pause",
            "async fn check(u: Capability<Unknown>, c: &LifecycleClient) { u.pause(c, \"key\").await; }",
            Some("E0599"),
        ),
        (
            "pending_pause",
            "async fn check(u: Pending<Unknown>, c: &LifecycleClient) { u.retry_pause(c).await; }",
            Some("E0599"),
        ),
        (
            "preclaimed_reservation_power",
            "async fn check(p: Capability<Preclaimed>, c: &LifecycleClient) { p.delete(c, \"key\").await; }",
            Some("E0599"),
        ),
        (
            "claimed_reservation_power",
            "async fn check(p: Capability<Claimed>, c: &LifecycleClient) { p.delete(c, \"key\").await; }",
            Some("E0599"),
        ),
        (
            "consumed",
            "async fn check(r: Capability<Running>, c: &LifecycleClient) { let _ = r.pause(c, \"key\").await; r.delete(c, \"other\").await; }",
            Some("E0382"),
        ),
    ];
    for (name, body, diagnostic) in cases {
        let source = out.join(format!("{name}.rs"));
        fs::write(&source, format!("#![allow(dead_code, unused_imports)]\nuse cmux_cloud_client::lifecycle::{{Capability, Pending, LifecycleClient}};\nuse cmux_lifeline::vm::{{Running, Paused, Deleted, Unknown, Preclaimed, Claimed}};\n{body}\n")).unwrap();
        let output = Command::new("rustc")
            .args(["--edition=2024", "--crate-type=lib", "--emit=metadata"])
            .arg("--out-dir")
            .arg(&out)
            .arg("-L")
            .arg(format!("dependency={}", deps.display()))
            .arg("--extern")
            .arg(format!("cmux_cloud_client={}", client.display()))
            .arg("--extern")
            .arg(format!("cmux_lifeline={}", lifeline.display()))
            .arg(&source)
            .output()
            .unwrap();
        let stderr = String::from_utf8_lossy(&output.stderr);
        match diagnostic {
            None => assert!(output.status.success(), "positive API control failed: {stderr}"),
            Some(code) => {
                assert!(!output.status.success(), "{name} incorrectly compiled");
                assert!(stderr.contains(code), "{name}: expected {code}: {stderr}");
            }
        }
    }
    fs::remove_dir_all(out).unwrap();
}
