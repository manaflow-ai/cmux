use super::*;
use cmux_sign_clone_sweep::Reason;
use std::path::PathBuf;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().copied().map(str::to_owned).collect()
}

#[test]
fn sign_clones_claims_only_its_command() {
    assert_eq!(run_if_requested(&args(&["status"])), None);
    assert_eq!(run_if_requested(&args(&["sign-clones", "--help"])), Some(0));
    assert_eq!(run_if_requested(&args(&["sign-clones", "sweep", "--bogus"])), Some(2));
}

#[test]
fn sign_clones_rows_name_the_bundle_reason_and_evidence() {
    let removed = Row {
        path: PathBuf::from("/x/a.code_sign_clone/code_sign_clone.abcdef"),
        root_id: "com.cmuxterm.app.nightly".into(),
        verdict: Verdict::Removed { reason: Reason::Superseded, dry_run: true },
        reclaimable_bytes: 812_400_000,
    };
    let row = row_json(&removed);
    assert_eq!(row.get("verdict"), Some(&json!("would-remove")));
    assert_eq!(row.get("reason"), Some(&json!("superseded")));
    assert_eq!(row.get("bundle_id"), Some(&json!("com.cmuxterm.app.nightly")));
    assert_eq!(row.get("reclaimable_bytes"), Some(&json!(812_400_000u64)));
    let foreign =
        Row { verdict: Verdict::Foreign { found: Some("org.example.Browser".into()) }, ..removed };
    assert_eq!(bundle_id(&foreign), Some("org.example.Browser"));
    assert_eq!(size(812_400_000), "812.4 MB");
    assert_eq!(size(512), "512 B");
}
