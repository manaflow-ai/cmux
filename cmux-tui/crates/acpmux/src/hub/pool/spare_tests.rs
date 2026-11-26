use super::*;

fn r(harness: &str, cwd: &str, at: u64) -> Remembered {
    Remembered {
        harness: harness.into(),
        preset: None,
        cwd: cwd.into(),
        model: None,
        used_at_ms: at,
    }
}

#[test]
fn each_harness_is_remembered_once_with_its_newest_folder() {
    let mut list = vec![r("claude", "/a", 1), r("codex", "/a", 2)];
    remember(&mut list, r("claude", "/b", 3));
    assert_eq!(list, vec![r("codex", "/a", 2), r("claude", "/b", 3)]);
}

#[test]
fn an_older_shape_arriving_late_never_replaces_a_newer_one() {
    let mut list = vec![r("claude", "/b", 5)];
    remember(&mut list, r("claude", "/a", 4));
    assert_eq!(list, vec![r("claude", "/b", 5)]);
}

#[test]
fn only_a_harness_used_in_the_last_week_starts_a_spare() {
    let week = u64::try_from(RECENT.as_millis()).unwrap();
    let list = vec![r("claude", "/a", 10), r("codex", "/a", week + 20)];
    assert_eq!(recent(&list, week + 30), vec![r("codex", "/a", week + 20)]);
}

#[test]
fn the_file_round_trips_and_a_bad_file_reads_as_none() {
    let dir = std::env::temp_dir().join(format!("acpmux-spares-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(FILE);
    assert!(read_file(&path).is_empty());
    write_file(&path, vec![r("claude", "/a", 1)]).unwrap();
    assert_eq!(read_file(&path), vec![r("claude", "/a", 1)]);
    std::fs::write(&path, b"{not json").unwrap();
    assert!(read_file(&path).is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_harness_whose_spare_idled_out_is_missing_and_a_warming_or_ready_one_is_not() {
    let list = vec![r("claude", "/a", 10), r("codex", "/a", 20)];
    // The claude spare idled out; the codex one is warming or ready.
    let gone = missing(&list, 30, |h| h == "codex");
    assert_eq!(gone, vec![r("claude", "/a", 10)]);
    assert!(missing(&list, 30, |_| true).is_empty(), "no spare is wanted twice");
    let week = u64::try_from(RECENT.as_millis()).unwrap();
    assert!(missing(&list, week + 100, |_| false).is_empty(), "only a recent harness");
}

#[test]
fn a_reserve_moves_home_chat_shapes_to_its_folder_and_remembers_the_persons_picks() {
    let home = std::path::Path::new("/home/p");
    let old = "/home/p/chats/r0123456789abcdef0123456789abcdef";
    let next = std::path::Path::new("/home/p/chats/rfedcba9876543210fedcba9876543210");
    // A Codex home chat in the folder it took, and a harness used in a project folder.
    let mut list = vec![r("codex", old, 5), r("opencode", "/home/p/src/app", 6)];
    let given = vec![super::reserved::HomeShape {
        harness: "claude".into(),
        preset: None,
        model: Some("opus".into()),
    }];
    home_shapes(&mut list, home, next, given, 9);
    let next_s = next.to_str().unwrap();
    let mut claude = r("claude", next_s, 9);
    claude.model = Some("opus".into());
    assert_eq!(
        list,
        vec![r("codex", next_s, 5), r("opencode", "/home/p/src/app", 6), claude],
        "the home chat's harness waits in the next folder with its old use time; a project \
         folder's stays"
    );
}

#[test]
fn the_shapes_sent_read_the_file_this_pool_writes() {
    let mut codex = r("codex", "/a", 50);
    codex.model = Some("gpt-5.5".into());
    let list =
        vec![r("claude", "/a", 10), codex, r("a", "/a", 20), r("b", "/a", 30), r("c", "/a", 40)];
    let bytes = serde_json::to_vec(&SpareFile { spares: list }).unwrap();
    let sent: Vec<Value> = cmux_cloud_start_core::spare_shapes::shapes(&bytes, 60)
        .into_iter()
        .map(|s| serde_json::to_value(s).unwrap())
        .collect();
    assert_eq!(sent.len(), 4);
    assert_eq!(sent[0], json!({"harness": "codex", "model": "gpt-5.5"}));
    assert!(sent.iter().all(|v| v.get("cwd").is_none()));
    assert!(!sent.contains(&json!({"harness": "claude"})), "the oldest is left out");
}
