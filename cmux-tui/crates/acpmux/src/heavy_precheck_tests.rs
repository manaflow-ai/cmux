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

    let small = Shape { disk_free: 10 * GB, ..default_vm() };
    let w = precheck("cmake -S llvm -B build -G Ninja", &small, &nowhere()).unwrap();
    assert_eq!(w.project, Some(Project::Llvm));
    assert_eq!(w.text, "LLVM needs 15 to 20 GB of disk; this machine has 10 GB free.");
    assert_eq!(w.short, vec![Short::Disk], "LLVM publishes no memory minimum");
    let in_llvm = Place { cwd: Some("/home/me/llvm-project/build"), checkout_bytes: None };
    assert_eq!(precheck("ninja", &small, &in_llvm).unwrap().project, Some(Project::Llvm));
    let w = precheck("cmake -G Ninja ../llvm", &small, &nowhere()).unwrap();
    assert_eq!(w.project, Some(Project::Llvm));
    assert_eq!(w.needs_memory, None);
}

#[test]
fn published_disk_minimums_warn_only_below_the_boundary() {
    for (project, command) in [
        (Project::Chromium, "fetch chromium"),
        (Project::Llvm, "cmake -S llvm -B build"),
        (Project::Rustc, "./x.py build"),
    ] {
        let (disk, _) = project.minimums();
        for disk_free in [disk - 1, disk, disk + 1] {
            let shape = Shape { disk_free, ..big_vm() };
            let warning = precheck(command, &shape, &nowhere());
            assert_eq!(warning.is_some(), disk_free < disk, "{command}: {disk_free}");
            if let Some(warning) = warning {
                assert_eq!(warning.short, vec![Short::Disk]);
                assert_eq!(warning.project, Some(project));
            }
        }
    }
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
        "bazelisk build //...",
        "bazel build //foo:bar //...",
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
        "bazelisk build //foo:bar",
        "bazel build //foo/...",
        "bazel build //foo:all",
        "bazel query //...",
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
