use super::BuildIdentity;
use std::path::Path;

/// Every vectors case's `app_daemon.state_dir` (CmuxNext's
/// `daemonStateDirectory(appSupport:)` of the same build): a pure path,
/// no real build's directory is touched.
#[test]
fn the_daemon_state_dir_is_the_vectors_one() {
    let text = include_str!("../../../../schemas/build-identity/vectors.json");
    let vectors: serde_json::Value = serde_json::from_str(text).unwrap();
    let app_support = Path::new(vectors["app_support"].as_str().unwrap());
    let mut wrong = Vec::new();
    for case in vectors["cases"].as_array().unwrap() {
        let build = BuildIdentity::new(case["bundle_id"].as_str(), case["bundled_tag"].as_str());
        let want = case["app_daemon"]["state_dir"].as_str().map(std::path::PathBuf::from);
        let got = build.daemon_state_dir(app_support);
        if got != want {
            wrong.push(format!("{}: {got:?} (want {want:?})", case["name"]));
        }
    }
    assert!(wrong.is_empty(), "daemon state dirs of the wrong build:\n{}", wrong.join("\n"));
}
