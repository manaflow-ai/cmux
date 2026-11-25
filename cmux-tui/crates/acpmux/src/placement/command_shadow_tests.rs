use super::*;

fn situation() -> Situation {
    Situation { agent_vm: AGENT_VM_START, heavy_running: 0, fork_p95_ms: None }
}

fn known(wall_s: Option<f64>, vcpu: f64, mem_gib: f64) -> Predicted {
    Predicted {
        source: Source::History,
        runs: 3,
        wall_s,
        need: Some(Shape { vcpu, mem_gib }),
        listens: false,
        outlives: false,
        third_party: false,
    }
}

const UNKNOWN: Predicted = Predicted {
    source: Source::None,
    runs: 0,
    wall_s: None,
    need: None,
    listens: false,
    outlives: false,
    third_party: false,
};

// One test per row of RFD 0144's "Where a command runs" table.

#[test]
fn row_1_short_and_fits_runs_here() {
    let v = decide(&known(Some(0.4), 0.5, 0.2), &situation());
    assert_eq!((v.decision, v.row), (Decision::Here, Row::Short));
    assert_eq!(v.shape, AGENT_VM_START);
}

#[test]
fn row_2_bounded_under_the_grow_ceiling_grows_in_place() {
    let v = decide(&known(Some(90.0), 6.0, 9.0), &situation());
    assert_eq!((v.decision, v.row), (Decision::Grow, Row::GrowInPlace));
    assert_eq!(v.shape, Shape { vcpu: 6.0, mem_gib: 9.0 });
    // At the ceiling exactly still grows.
    let v = decide(&known(Some(90.0), 8.0, 16.0), &situation());
    assert_eq!((v.decision, v.shape), (Decision::Grow, GROW_CEILING));
}

#[test]
fn row_2_a_long_command_that_already_fits_stays_here_ungrown() {
    let v = decide(&known(Some(120.0), 1.0, 1.0), &situation());
    assert_eq!((v.decision, v.row), (Decision::Here, Row::GrowInPlace));
}

#[test]
fn row_3_past_the_grow_ceiling_runs_on_a_run_vm_at_the_predicted_shape() {
    let v = decide(&known(Some(400.0), 31.2, 40.0), &situation());
    assert_eq!((v.decision, v.row), (Decision::RunVm, Row::Heavy));
    assert_eq!(v.shape, Shape { vcpu: 32.0, mem_gib: 40.0 });
    // Never past 64 vCPU.
    let v = decide(&known(Some(400.0), 200.0, 40.0), &situation());
    assert_eq!(v.shape.vcpu, MAX_WORKLOAD_VCPU);
    // Memory alone past the ceiling is enough.
    let v = decide(&known(Some(30.0), 2.0, 24.0), &situation());
    assert_eq!(v.decision, Decision::RunVm);
}

#[test]
fn row_3_a_second_heavy_command_at_once_runs_on_a_run_vm() {
    let s = Situation { heavy_running: 1, ..situation() };
    let v = decide(&known(Some(90.0), 6.0, 9.0), &s);
    assert_eq!((v.decision, v.row), (Decision::RunVm, Row::Heavy));
    // A small one beside it still runs here.
    let v = decide(&known(Some(1.0), 0.5, 0.5), &s);
    assert_eq!(v.decision, Decision::Here);
}

#[test]
fn row_4_a_command_that_listens_or_outlives_its_call_is_served() {
    let p = Predicted { listens: true, ..known(Some(2.0), 0.5, 0.5) };
    let v = decide(&p, &situation());
    assert_eq!((v.decision, v.row), (Decision::ServeVm, Row::Listens));
    let p = Predicted { outlives: true, ..UNKNOWN };
    let v = decide(&p, &situation());
    assert_eq!((v.decision, v.row), (Decision::ServeVm, Row::Listens));
    assert_eq!(v.shape, AGENT_VM_START, "an unknown server gets the agent VM's start shape");
    // Listening wins over heavy.
    let p = Predicted { listens: true, ..known(Some(400.0), 31.2, 40.0) };
    assert_eq!(decide(&p, &situation()).decision, Decision::ServeVm);
}

#[test]
fn row_5_third_party_code_forks_even_when_small_once_forks_are_fast() {
    let p = Predicted { third_party: true, ..known(Some(3.0), 0.5, 0.5) };
    let fast = Situation { fork_p95_ms: Some(800), ..situation() };
    let v = decide(&p, &fast);
    assert_eq!((v.decision, v.row), (Decision::RunVm, Row::ThirdParty));
    // Until a fork's p95 is under 1 s, or while it is unmeasured, the size rows decide.
    for p95 in [None, Some(1_000), Some(4_000)] {
        let s = Situation { fork_p95_ms: p95, ..situation() };
        assert_eq!(decide(&p, &s).row, Row::Short, "p95 {p95:?}");
    }
}

#[test]
fn row_6_unknown_and_small_runs_here() {
    let v = decide(&UNKNOWN, &situation());
    assert_eq!((v.decision, v.row), (Decision::Here, Row::Unknown));
}

#[test]
fn rows_number_in_the_tables_order() {
    let rows =
        [Row::Short, Row::GrowInPlace, Row::Heavy, Row::Listens, Row::ThirdParty, Row::Unknown];
    assert_eq!(rows.map(Row::number), [1, 2, 3, 4, 5, 6]);
}

#[test]
fn a_class_names_the_program_and_its_verb_never_its_arguments() {
    let cases = [
        ("git status", "git status"),
        ("rg -n secret_token src/", "rg"),
        ("cd cmux-tui && cargo test -p acpmux placement", "cargo test"),
        ("pnpm run dev --port 3000", "pnpm run dev"),
        ("python3 -m pytest tests/x.py", "python3 -m pytest"),
        ("python3 /tmp/build_index.py --all", "python3 build_index.py"),
        ("FOO=1 timeout 60 npm test", "npm test"),
        ("ls -la; cargo build --release", "cargo build"),
        ("echo hi", "echo"),
        ("bash -lc 'swift build'", "swift build"),
        ("npx vitest run", "npx vitest"),
        ("git commit -m 'Fix the thing'", "git commit"),
    ];
    for (script, class) in cases {
        assert_eq!(class_of(script), class, "{script}");
    }
}

#[test]
fn a_first_sight_heavy_command_takes_its_class_default_and_runs_on_a_run_vm() {
    let table = Table::default();
    let p = table.predict("/r", "cargo build", "cargo build --release", false);
    assert_eq!(p.source, Source::ClassDefault);
    // cargo build: 8 vCPU / 15 GiB on top of the session's 2 / 2.
    assert_eq!(p.need, Some(Shape { vcpu: 10.0, mem_gib: 17.0 }));
    assert_eq!(decide(&p, &situation()).decision, Decision::RunVm);
    let p = table.predict("/r", "bun test", "bun test", false);
    assert_eq!(decide(&p, &situation()).decision, Decision::Grow);
}

#[test]
fn first_sight_classes_that_serve_or_install_are_known_by_class() {
    let table = Table::default();
    let p = table.predict("/r", "pnpm run dev", "pnpm run dev", false);
    assert!(p.listens);
    assert_eq!(decide(&p, &situation()).decision, Decision::ServeVm);
    let p = table.predict("/r", "pnpm install", "pnpm install", false);
    assert!(p.third_party && !p.listens);
    let p = table.predict("/r", "sleep", "sleep 600", true);
    assert!(p.outlives, "a background shell outlives its call");
    let p = table.predict("/r", "git status", "git status", false);
    assert_eq!((p.source, p.listens, p.third_party), (Source::None, false, false));
}

#[test]
fn the_table_predicts_from_the_last_runs_of_the_class_in_that_repository() {
    let mut table = Table::default();
    for wall in [1.0, 2.0, 50.0] {
        let run = Run {
            wall_s: wall,
            cpu_s: Some(wall * 0.5),
            peak_mem_gib: Some(0.1),
            listened: false,
            outlived: false,
        };
        table.record("/r", "pytest", run);
    }
    let p = table.predict("/r", "pytest", "pytest", false);
    assert_eq!((p.source, p.runs, p.wall_s), (Source::History, 3, Some(2.0)));
    let need = p.need.unwrap();
    assert!((need.mem_gib - 0.15).abs() < 1e-9 && (need.vcpu - 0.5).abs() < 1e-9, "{need:?}");
    assert_eq!(decide(&p, &situation()).row, Row::Short);
    // Another repository knows nothing of it.
    assert_eq!(table.predict("/other", "pytest", "pytest", false).source, Source::None);
    // Only the last runs count.
    for _ in 0..HISTORY_RUNS {
        let run = Run {
            wall_s: 30.0,
            cpu_s: Some(300.0),
            peak_mem_gib: Some(4.0),
            listened: true,
            outlived: true,
        };
        table.record("/r", "pytest", run);
    }
    let p = table.predict("/r", "pytest", "pytest", false);
    assert_eq!((p.runs, p.wall_s, p.listens, p.outlives), (HISTORY_RUNS, Some(30.0), true, true));
}

#[test]
fn the_table_keeps_a_bounded_number_of_classes() {
    let mut table = Table::default();
    let run = Run {
        wall_s: 1.0,
        cpu_s: Some(0.1),
        peak_mem_gib: Some(0.1),
        listened: false,
        outlived: false,
    };
    for i in 0..MAX_CLASSES + 10 {
        table.record("/r", &format!("tool{i}"), run);
    }
    assert_eq!(table.classes.len(), MAX_CLASSES);
    assert_eq!(table.predict("/r", "tool0", "tool0", false).source, Source::None, "oldest dropped");
}

#[test]
fn one_run_of_a_class_that_listened_does_not_make_the_class_a_server() {
    // The lane VM read-back: `python3 -c` ran a loop, then a listener, then a loop again; the
    // listener's one run made the next loop a serve VM.
    let mut table = Table::default();
    let run = |listened| Run {
        wall_s: 1.0,
        cpu_s: Some(0.5),
        peak_mem_gib: Some(0.1),
        listened,
        outlived: false,
    };
    for listened in [false, false, true] {
        table.record("/r", "python3", run(listened));
    }
    let p = table.predict("/r", "python3", "python3 -c 'print(1)'", false);
    assert!(!p.listens);
    assert_eq!(decide(&p, &situation()).decision, Decision::Here);
    for _ in 0..2 {
        table.record("/r", "python3", run(true));
    }
    assert!(table.predict("/r", "python3", "python3", false).listens, "3 of 5 listened");
}
