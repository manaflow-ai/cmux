use super::*;
use serde_json::json;

fn run(dir: &Path, args: &[&str]) {
    let ok = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
        .args(args)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("git runs")
        .success();
    assert!(ok, "git {args:?}");
}

#[test]
fn idle_digest_is_off_by_default() {
    assert!(!enabled_with(None, None));
    assert!(!enabled_with(Some(&json!({})), None));
    assert!(!enabled_with(
        Some(&json!({"agents": {"harnessMagic": {"idleDigest": {"enabled": false}}}})),
        None
    ));
    assert!(enabled_with(
        Some(&json!({"agents": {"harnessMagic": {"idleDigest": {"enabled": true}}}})),
        None
    ));
    assert!(enabled_with(None, Some("1")));
    assert!(!enabled_with(
        Some(&json!({"agents": {"harnessMagic": {"idleDigest": {"enabled": true}}}})),
        Some("0")
    ));
    assert_eq!(super::super::harness_magic::env_key(FEATURE), "ACPMUX_HM_IDLEDIGEST");
}

#[test]
fn idle_digest_is_a_registered_feature() {
    let names: Vec<&str> = super::super::harness_magic::FEATURES.iter().map(|f| f.name).collect();
    assert!(names.contains(&FEATURE), "{names:?}");
    assert!(names.contains(&"outputCaps"), "{names:?}");
}

#[test]
fn idle_digest_parses_counts_and_its_marker() {
    assert_eq!(parse_counts("3\t7"), Some((3, 7)));
    assert_eq!(parse_counts("x"), None);
    let state =
        State { head: "a".repeat(40), upstream_head: Some("b".repeat(40)), ..State::default() };
    let text = render(Path::new("/w"), &state, "2026-11-27T00:00:00Z", None, None);
    assert_eq!(
        parse_marker(&text),
        Some(("a".repeat(40), Some("b".repeat(40)), "2026-11-27T00:00:00Z".into()))
    );
    let bare =
        render(Path::new("/w"), &State { head: "c".into(), ..State::default() }, "t", None, None);
    assert_eq!(parse_marker(&bare), Some(("c".into(), None, "t".into())));
    assert_eq!(parse_marker("no marker"), None);
}

#[test]
fn idle_digest_caps_the_files_it_lists() {
    let dirty: Vec<String> = (0..MAX_FILES + 5).map(|i| format!("?? f{i}")).collect();
    let state = State { head: "h".into(), dirty, ..State::default() };
    let text = render(Path::new("/w"), &state, "t", None, None);
    assert!(text.contains(&format!("{} uncommitted file(s)", MAX_FILES + 5)), "{text}");
    assert!(text.contains("and 5 more"), "{text}");
    assert!(!text.contains(&format!("f{}", MAX_FILES + 1)), "{text}");
}

#[test]
fn idle_digest_writes_nothing_outside_a_repository() {
    let home = tempfile::tempdir().unwrap();
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(write_blocking(home.path(), "s1", dir.path(), Moment::Sleep), None);
    assert!(!path_in(home.path(), "s1").exists());
}

#[test]
fn idle_digest_names_what_moved_while_asleep() {
    let home = tempfile::tempdir().unwrap();
    let repo = tempfile::tempdir().unwrap();
    let dir = repo.path();
    run(dir, &["init", "-q", "-b", "main"]);
    std::fs::write(dir.join("a.txt"), "one\n").unwrap();
    run(dir, &["add", "a.txt"]);
    run(dir, &["commit", "-q", "-m", "first"]);
    std::fs::write(dir.join("a.txt"), "one\ntwo\n").unwrap();
    std::fs::write(dir.join("new.txt"), "x\n").unwrap();

    let wrote = write_blocking(home.path(), "s1", dir, Moment::Sleep).expect("a digest at sleep");
    let slept = std::fs::read_to_string(path_in(home.path(), "s1")).unwrap();
    assert_eq!(slept.len(), wrote);
    assert!(slept.contains("at sleep"), "{slept}");
    assert!(slept.contains("Branch `main`"), "{slept}");
    assert!(slept.contains("No upstream"), "{slept}");
    assert!(slept.contains("2 uncommitted file(s)"), "{slept}");
    assert!(slept.contains("M a.txt"), "{slept}");
    assert!(slept.contains("?? new.txt"), "{slept}");

    run(dir, &["add", "-A"]);
    run(dir, &["commit", "-q", "-m", "second while asleep"]);
    write_blocking(home.path(), "s1", dir, Moment::Wake).expect("a digest at wake");
    let woke = std::fs::read_to_string(path_in(home.path(), "s1")).unwrap();
    assert!(woke.contains("at wake"), "{woke}");
    assert!(woke.contains("HEAD gained 1 commit(s)"), "{woke}");
    assert!(woke.contains("second while asleep"), "{woke}");
    assert!(woke.contains("Working tree clean"), "{woke}");

    // A second wake with nothing new says so.
    write_blocking(home.path(), "s1", dir, Moment::Sleep).unwrap();
    write_blocking(home.path(), "s1", dir, Moment::Wake).unwrap();
    let still = std::fs::read_to_string(path_in(home.path(), "s1")).unwrap();
    assert!(still.contains("Nothing moved"), "{still}");
}
