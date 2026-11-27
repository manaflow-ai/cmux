use super::*;
use serde_json::json;

const GIB: u64 = 1 << 30;

/// RFD 0063's default chat VM: 2 vCPU / 4 GiB / 20 GiB, with about 20 GB free.
fn default_vm() -> Shape {
    Shape { vcpu: 2, mem_total: 4 * GIB, mem_available: Some(3 * GIB), disk_free: 20 * GB }
}

fn big_vm() -> Shape {
    Shape { vcpu: 32, mem_total: 64 * GIB, mem_available: Some(60 * GIB), disk_free: 200 * GB }
}

fn nowhere() -> Place<'static> {
    Place::default()
}

#[test]
fn fetch_chromium_on_the_default_vm_reads_like_the_rfd() {
    let w = precheck("fetch --nohooks chromium", &default_vm(), &nowhere()).expect("warns");
    assert_eq!(w.project, Some(Project::Chromium));
    assert_eq!(w.short, vec![Short::Disk, Short::Memory]);
    assert_eq!(w.command, "fetch --nohooks chromium");
    assert_eq!(
        w.text,
        "Chromium needs 100 GB of disk and 16 GB of memory; this machine has 20 GB free and 4 GB. \
         About 20 hours here if it fit, about 1.5 hours and $3 on 32 vCPU."
    );
}

#[test]
fn chromium_commands_are_known() {
    for script in [
        "fetch chromium",
        "cd ~/chromium/src && autoninja -C out/Default chrome",
        "ninja -C out/Default chrome",
        "ninja -Cout/Release",
        "bash -lc 'ninja -C src/out/x'",
        "/home/me/depot_tools/autoninja chrome",
    ] {
        let w = precheck(script, &default_vm(), &nowhere());
        assert_eq!(w.map(|w| w.project), Some(Some(Project::Chromium)), "{script}");
    }
}

#[test]
fn a_machine_that_meets_the_minimums_gets_no_row() {
    assert_eq!(precheck("fetch chromium", &big_vm(), &nowhere()), None);
    // 16 GiB sold shows a little under 16 GiB in MemTotal; it still meets "16 GB".
    let pro =
        Shape { vcpu: 8, mem_total: 15 * GIB + GIB / 2, mem_available: None, disk_free: 128 * GB };
    assert_eq!(precheck("autoninja chrome", &pro, &nowhere()), None);
}

#[test]
fn only_what_is_short_is_named() {
    let roomy_disk = Shape { disk_free: 150 * GB, ..default_vm() };
    let w = precheck("autoninja chrome", &roomy_disk, &nowhere()).unwrap();
    assert_eq!(w.short, vec![Short::Memory]);
    assert_eq!(w.needs_memory, Some(16 * GB));
    assert_eq!(w.needs_disk, Some(100 * GB));
}

#[test]
fn the_burst_clause_is_left_out_on_a_burst_size_machine() {
    let small_disk = Shape { disk_free: 50 * GB, ..big_vm() };
    let w = precheck("fetch chromium", &small_disk, &nowhere()).unwrap();
    assert_eq!(
        w.text,
        "Chromium needs 100 GB of disk and 16 GB of memory; this machine has 50 GB free and 69 GB. \
         About 1.5 hours here if it fit."
    );
}

#[test]
fn rustc_and_llvm_use_their_published_minimums() {
    let w = precheck("./x.py build --stage 2", &default_vm(), &nowhere()).unwrap();
    assert_eq!(w.project, Some(Project::Rustc));
    assert_eq!(
        w.text,
        "rustc needs 30 GB of disk and 8 GB of memory; this machine has 20 GB free and 4 GB."
    );
    assert_eq!(
        precheck("python3 x.py dist", &default_vm(), &nowhere()).unwrap().project,
        Some(Project::Rustc)
    );
    assert_eq!(precheck("./x test tidy", &default_vm(), &nowhere()), None, "only a build");

    let w = precheck("cmake -S llvm -B build -G Ninja", &default_vm(), &nowhere()).unwrap();
    assert_eq!(w.project, Some(Project::Llvm));
    assert_eq!(w.text, "LLVM needs 15 to 20 GB of disk; this machine has 20 GB free.");
    assert_eq!(w.short, vec![Short::Disk], "LLVM publishes no memory minimum");
    let small = Shape { disk_free: 10 * GB, ..default_vm() };
    let in_llvm = Place { cwd: Some("/home/me/llvm-project/build"), checkout_bytes: None };
    assert_eq!(precheck("ninja", &small, &in_llvm).unwrap().project, Some(Project::Llvm));
    let w = precheck("cmake -G Ninja ../llvm", &small, &nowhere()).unwrap();
    assert_eq!(w.project, Some(Project::Llvm));
    assert_eq!(w.needs_memory, None);
}

#[test]
fn a_big_build_warns_only_in_a_checkout_past_eight_times_free_memory() {
    let shape = default_vm(); // 3 GiB free: the line is 24 GiB.
    let big = Place { cwd: None, checkout_bytes: Some(40 * GIB) };
    let small = Place { cwd: None, checkout_bytes: Some(2 * GIB) };
    for script in [
        "cargo build --release",
        "cargo +nightly build",
        "make -j8",
        "make --jobs=4",
        "bazel build //...",
    ] {
        let w = precheck(script, &shape, &big).unwrap_or_else(|| panic!("{script} warns"));
        assert_eq!(w.project, None);
        assert_eq!(w.needs_memory, Some(5 * GIB));
        assert_eq!(precheck(script, &shape, &small), None, "{script} in a small checkout");
        assert_eq!(precheck(script, &shape, &nowhere()), None, "{script}: size unknown");
    }
    let w = precheck("cargo build --release", &shape, &big).unwrap();
    assert_eq!(
        w.text,
        "This build wants more than this machine has: `cargo build --release` in a 40 GiB checkout, \
         with 3.0 GiB of memory free on 2 vCPUs."
    );
}

#[test]
fn what_is_not_a_known_heavy_job_never_warns() {
    let big = Place { cwd: Some("/src/chromium"), checkout_bytes: Some(400 * GIB) };
    for script in [
        "cargo test",
        "make",
        "bazel build //foo:bar",
        "echo 'fetch chromium'",
        "git log -- autoninja",
        "ninja -C build",
        "cat <<EOF\nautoninja chrome\nEOF",
        "fetch v8",
    ] {
        assert_eq!(precheck(script, &default_vm(), &big), None, "{script}");
    }
}

#[test]
fn a_tool_call_is_prechecked_from_its_command() {
    let bash = json!({"sessionUpdate": "tool_call", "kind": "execute",
        "rawInput": {"command": "cd src && autoninja -C out/Default chrome"}});
    assert_eq!(
        precheck_tool(&bash, &default_vm(), &nowhere()).map(|w| w.project),
        Some(Some(Project::Chromium))
    );
    let argv =
        json!({"kind": "execute", "rawInput": {"command": ["bash", "-lc", "fetch chromium"]}});
    assert!(precheck_tool(&argv, &default_vm(), &nowhere()).is_some());
    let in_llvm = json!({"kind": "execute",
        "rawInput": {"command": ["ninja"], "cwd": "/w/llvm-project/build"}});
    let small = Shape { disk_free: 10 * GB, ..default_vm() };
    assert_eq!(precheck_tool(&in_llvm, &small, &nowhere()).unwrap().project, Some(Project::Llvm));
    let read = json!({"kind": "read", "rawInput": {"command": "fetch chromium"}});
    assert_eq!(precheck_tool(&read, &default_vm(), &nowhere()), None);
}

#[test]
fn the_warning_serializes_camel_case_for_the_chat_row() {
    let w = precheck("fetch chromium", &default_vm(), &nowhere()).unwrap();
    let v = serde_json::to_value(&w).unwrap();
    assert_eq!(v["project"], "chromium");
    assert_eq!(v["short"], json!(["disk", "memory"]));
    assert_eq!(v["needsDisk"], 100 * GB);
    assert_eq!(v["needsMemory"], 16 * GB);
}

#[test]
fn a_known_heavy_project_floors_the_run_vm_at_its_published_memory() {
    assert_eq!(memory_floor("fetch --nohooks chromium", None), Some((Project::Chromium, 16 * GB)));
    assert_eq!(memory_floor("./x.py build", None), Some((Project::Rustc, 8 * GB)));
    // The largest of several wins.
    assert_eq!(
        memory_floor("./x.py build && autoninja -C out/Default chrome", None),
        Some((Project::Chromium, 16 * GB))
    );
    // LLVM publishes only disk; a big build has no published minimum; the rest is not heavy.
    assert_eq!(memory_floor("cmake -S llvm -B build", None), None);
    assert_eq!(memory_floor("cargo build", None), None);
    assert_eq!(memory_floor("ls -la", None), None);
}

#[test]
fn the_three_button_warning_is_a_notice_row_that_says_what_happens() {
    let w = precheck("fetch --nohooks chromium", &default_vm(), &nowhere()).expect("warns");
    let row = notice(&w, true);
    assert!(row.starts_with("[autosize] Chromium needs 100 GB of disk"), "{row}");
    assert!(row.ends_with("Running it here; this machine grows as it works."), "{row}");
    assert!(!row.contains('?'), "a notice, not a question: {row}");
    assert!(notice(&w, false).ends_with("Running it here as it is."));
}

#[test]
fn only_known_heavy_commands_read_the_machine() {
    assert!(is_known_heavy("fetch chromium", None));
    assert!(is_known_heavy("cd src && cargo build --release", None));
    assert!(!is_known_heavy("cargo test", None));
    assert!(!is_known_heavy("git status", None));
}

#[test]
fn meminfo_reads_total_and_available_in_bytes() {
    let text =
        "MemTotal:        4028264 kB\nMemFree:          123 kB\nMemAvailable:    3000000 kB\n";
    assert_eq!(parse_meminfo(text), (Some(4028264 * 1024), Some(3000000 * 1024)));
    assert_eq!(parse_meminfo("MemTotal: 10 kB\n"), (Some(10 * 1024), None));
    assert_eq!(parse_meminfo(""), (None, None));
}
