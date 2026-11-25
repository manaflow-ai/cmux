use super::*;
use crate::session_budget::Total;

#[test]
fn a_session_slice_nests_under_the_sessions_slice_and_keeps_only_letters_and_digits() {
    assert_eq!(slice_name("019a-b2c3_d4.e5").as_deref(), Some("acpmuxsessions-019ab2c3d4e5.slice"));
    assert_eq!(slice_name("--__"), None);
    let long = "a".repeat(200);
    assert_eq!(slice_name(&long).unwrap().len(), PREFIX.len() + 64 + ".slice".len());
    // One dash after the parent's name: a child of `acpmuxsessions.slice`, never deeper.
    let name = slice_name("x-y-z").unwrap();
    assert_eq!(name.matches('-').count(), 1);
    assert!(name.starts_with(&crate::session_scope::SESSIONS_SLICE.replace(".slice", "-")));
}

#[test]
fn the_slice_request_carries_only_the_limits_that_are_on() {
    let total = Total { memory_max: 1 << 30, tasks_max: Some(64), cpu_quota: 0 };
    let joined = busctl_args("acpmuxsessions-abc.slice", &total).join(" ");
    assert!(joined.starts_with("--user --quiet call org.freedesktop.systemd1 "), "{joined}");
    assert!(
        joined.contains("StartTransientUnit ssa(sv)a(sa(sv)) acpmuxsessions-abc.slice fail 3"),
        "{joined}"
    );
    assert!(joined.contains("MemoryMax t 1073741824 TasksMax t 64 0"), "{joined}");
    assert!(!joined.contains("CPUQuota"), "{joined}");
    assert!(already_exists("Unit acpmuxsessions-abc.slice already exists."));
    assert!(!already_exists("Access denied"));
}

#[test]
fn a_task_scope_in_a_session_slice_is_found_there() {
    let unit = crate::agent_host::scope::scope_unit(4242, "0a1b2c3d");
    let slice = "acpmuxsessions-abc.slice";
    let joined = crate::agent_host::scope::busctl_args_in(&unit, 4242, slice, &[]).join(" ");
    assert!(joined.contains("Slice s acpmuxsessions-abc.slice"), "{joined}");
    let cgroup = format!(
        "0::/user.slice/user-1000.slice/user@1000.service/acpmuxsessions.slice/{slice}/{unit}\n"
    );
    assert!(crate::agent_host::scope::names_scope_in(&cgroup, slice, &unit));
    assert!(!crate::agent_host::scope::names_scope(&cgroup, &unit));
}

#[test]
fn an_empty_session_slice_is_stopped_only_after_it_stayed_empty() {
    let mut sweep = Sweep::default();
    let t0 = Instant::now();
    let slices = vec![
        ("acpmuxsessions-a.slice".to_owned(), false),
        ("acpmuxsessions-b.slice".to_owned(), true),
    ];
    assert!(sweep.tick(&slices, t0).is_empty());
    assert!(sweep.tick(&slices, t0 + EMPTY_FOR / 2).is_empty());
    assert_eq!(sweep.tick(&slices, t0 + EMPTY_FOR), vec!["acpmuxsessions-a.slice".to_owned()]);
    // A scope joined again: the clock starts over.
    let mut sweep = Sweep::default();
    sweep.tick(&slices, t0);
    let busy = vec![("acpmuxsessions-a.slice".to_owned(), true)];
    sweep.tick(&busy, t0 + EMPTY_FOR / 2);
    assert!(sweep.tick(&slices, t0 + EMPTY_FOR).is_empty());
}

#[test]
fn the_sweep_reads_session_slices_and_their_scopes() {
    let dir = tempfile::tempdir().unwrap();
    let sessions = dir.path().join(crate::session_scope::SESSIONS_SLICE);
    std::fs::create_dir_all(sessions.join("acpmuxsessions-a.slice/acpmux-x.scope")).unwrap();
    std::fs::create_dir_all(sessions.join("acpmuxsessions-b.slice")).unwrap();
    std::fs::create_dir_all(sessions.join("run-u1.scope")).unwrap();
    let mut got = session_slices(&dir.path().to_string_lossy());
    got.sort();
    assert_eq!(
        got,
        vec![
            ("acpmuxsessions-a.slice".to_owned(), true),
            ("acpmuxsessions-b.slice".to_owned(), false)
        ]
    );
}
