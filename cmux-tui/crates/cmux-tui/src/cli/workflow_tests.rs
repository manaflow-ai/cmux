use super::*;
use std::fs;

fn fixture() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let workflows = dir.path().join(".cmux/workflows");
    fs::create_dir_all(&workflows).unwrap();
    fs::write(workflows.join("nightly.workflow.js"), "return 42;").unwrap();
    (dir, workflows)
}

#[test]
fn start_resolves_and_pins_source_under_project_directory() {
    let (dir, _) = fixture();
    let invocation = parse(&["start".into(), "nightly.workflow.js".into()], dir.path()).unwrap();
    let Invocation::Start { name, source, args, .. } = invocation else { panic!("expected start") };
    assert_eq!(name, "nightly");
    assert_eq!(source, "return 42;");
    assert_eq!(args, json!([]));
}

#[test]
fn start_rejects_path_escape_and_non_workflow_suffix() {
    let (dir, workflows) = fixture();
    fs::write(dir.path().join("outside.js"), "return 1;").unwrap();
    assert!(parse(&["start".into(), "../outside.js".into()], dir.path()).is_err());
    assert!(parse(&["start".into(), "outside.js".into()], dir.path()).is_err());
    assert!(workflows.exists());
}

#[test]
fn lifecycle_and_hidden_runner_require_exact_arguments() {
    assert!(parse(&["pause".into()], Path::new(".")).is_err());
    assert!(parse(&["__run".into(), "--run-id".into(), "wf".into()], Path::new(".")).is_err());
    let run = parse(
        &["__run".into(), "--run-id".into(), "wf".into(), "--generation".into(), "7".into()],
        Path::new("."),
    )
    .unwrap();
    assert!(matches!(run, Invocation::Run { generation: 7, .. }));
}
