//! A Cloud start's folder check before any machine: every absolute folder goes on, whatever its
//! size, a parent of repositories past the copy's limits (`~/Projects`) above all, and its answer
//! carries the copy's estimate and decision, made before any machine exists.

use std::path::Path;

use super::super::super::sync_cli::size_cap;
use super::{floor_disk, grown_disk_gib, needed_disk, needed_size, planned_size, run};

fn write(top: &Path, relative: &str, bytes: usize) {
    let path = top.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, vec![b'x'; bytes]).unwrap();
}

fn canonical() -> (tempfile::TempDir, std::path::PathBuf) {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    (root, top)
}

#[test]
fn a_small_plain_folder_goes_on_whole() {
    let (_root, top) = canonical();
    write(&top, "notes/a.txt", 10);
    let answer = run(top.to_str().unwrap());
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["estimate"]["mode"], "whole", "{answer}");
    assert_eq!(answer["estimate"]["files"], 1, "{answer}");
    assert_eq!(answer["estimate"]["bytes"], 10, "{answer}");
    assert_eq!(answer["estimate"]["seconds"], 1, "{answer}");
    assert_eq!(answer["estimate_bytes"], 10, "{answer}");
    assert_eq!(answer["needed_size"], "sm", "{answer}");
}

/// Leo's `~/Projects`, refused before with the repositories inside it: it goes on now, as a
/// first pass that leaves the big file on this Mac, known before any machine.
#[test]
fn a_parent_of_repositories_past_the_limit_goes_on_from_a_first_pass() {
    let (_root, top) = canonical();
    for name in ["cmux", "web", "work/api"] {
        std::fs::create_dir_all(top.join(name).join(".git")).unwrap();
        write(&top, &format!("{name}/src/main.rs"), 64);
    }
    write(&top, "downloads/disk.img", 4096);
    let answer = size_cap::with_test_limits(1024, 3, || run(top.to_str().unwrap()));
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["estimate"]["mode"], "first_pass", "{answer}");
    assert!(answer["estimate"]["left_files"].as_u64().unwrap() >= 1, "{answer}");
    // Past the limits only a first pass goes, at most its own bytes.
    let sent = answer["estimate_bytes"].as_u64().unwrap();
    assert!(sent <= size_cap::FIRST_BYTES, "{answer}");
    assert_eq!(answer["needed_size"], "sm", "{answer}");
}

#[test]
fn a_big_plain_folder_with_no_repositories_goes_on() {
    let (_root, top) = canonical();
    for index in 0..8 {
        write(&top, &format!("photos/{index}.jpg"), 10);
    }
    let answer = size_cap::with_test_limits(1, 1, || run(top.to_str().unwrap()));
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["estimate"]["mode"], "first_pass", "{answer}");
    assert_eq!(answer["estimate"]["why"], "files", "{answer}");
    assert_eq!(answer["needed_size"], "sm", "{answer}");
}

#[test]
fn a_folder_that_cannot_be_read_still_goes_on() {
    let (_root, top) = canonical();
    let answer = run(top.join("gone").to_str().unwrap());
    assert_eq!(answer, serde_json::json!({"ok": true, "estimate": null}));
}

#[test]
fn a_relative_folder_is_a_usage_error() {
    assert_eq!(run("Projects")["error_code"], "usage.invalid");
}

/// A folder sent whole counts its repository history too: the machine holds it.
#[test]
fn a_whole_copy_counts_its_git_history() {
    let (_root, top) = canonical();
    std::fs::create_dir_all(top.join(".git")).unwrap();
    let init = std::process::Command::new("git").arg("init").arg("-q").arg(&top).status().unwrap();
    assert!(init.success());
    write(&top, "src/main.rs", 100);
    let answer = run(top.to_str().unwrap());
    assert!(answer["estimate_bytes"].as_u64().unwrap() > 100, "{answer}");
}

/// The needed disk (what a size grows toward under a plan known) is half again the folder, and at least the floor (the
/// folder and the 12 GiB reserve, what every refusal keeps): the reserve decides up to 24 GiB of folder, the half above.
#[test]
fn the_needed_disk_is_half_again_the_folder_and_at_least_the_floor() {
    const GIB: u64 = 1024 * 1024 * 1024;
    assert_eq!(floor_disk(0), 12 * GIB);
    assert_eq!(floor_disk(116 * GIB), 128 * GIB);
    assert_eq!(floor_disk(u64::MAX), u64::MAX);
    assert_eq!(needed_disk(0), 12 * GIB);
    assert_eq!(needed_disk(4 * GIB), 16 * GIB);
    assert_eq!(needed_disk(24 * GIB), 36 * GIB);
    assert_eq!(needed_disk(40 * GIB), 60 * GIB);
    // Half a byte rounds up.
    assert_eq!(needed_disk(40 * GIB + 1), 60 * GIB + 2);
    assert_eq!(needed_disk(u64::MAX), u64::MAX);
}

/// With no plan known, a start asks what it did before the half-again target: the smallest size whose own disk holds
/// the folder and the reserve, none past `xl`'s 116 GiB.
#[test]
fn the_needed_size_is_the_smallest_whose_disk_holds_the_floor() {
    const GIB: u64 = 1024 * 1024 * 1024;
    assert_eq!(needed_size(0), Some("sm"));
    assert_eq!(needed_size(4 * GIB), Some("sm"));
    assert_eq!(needed_size(4 * GIB + 1), Some("md"));
    assert_eq!(needed_size(20 * GIB), Some("md"));
    assert_eq!(needed_size(20 * GIB + 1), Some("lg"));
    assert_eq!(needed_size(48 * GIB), Some("lg"));
    assert_eq!(needed_size(52 * GIB), Some("lg"));
    assert_eq!(needed_size(52 * GIB + 1), Some("xl"));
    assert_eq!(needed_size(100 * GIB), Some("xl"));
    assert_eq!(needed_size(116 * GIB), Some("xl"));
    assert_eq!(needed_size(116 * GIB + 1), None);
    assert_eq!(needed_size(u64::MAX), None);
}

/// No plan known (none, or a size off the ladder): the needed size, its own disk, exactly as before.
#[test]
fn a_start_with_no_plan_known_asks_the_needed_size_and_grows_nothing() {
    const GIB: u64 = 1024 * 1024 * 1024;
    for plan_max in [None, Some("huge")] {
        assert_eq!(planned_size(48 * GIB, plan_max), Some("lg"));
        assert_eq!(grown_disk_gib(Some("lg"), Some(48 * GIB), plan_max), None);
        assert_eq!(planned_size(100 * GIB, plan_max), Some("xl"));
        assert_eq!(grown_disk_gib(Some("xl"), Some(100 * GIB), plan_max), None);
        assert_eq!(planned_size(117 * GIB, plan_max), None);
    }
}

/// Under a plan known by its largest size: the needed size when the plan gives it, its disk grown toward half again the
/// folder within the plan's disk; else the plan's largest size grown when the plan's disk holds the floor; else the
/// size past the plan, which the platform refuses with its upgrade.
#[test]
fn a_plan_known_asks_the_needed_size_or_its_largest_grown() {
    const GIB: u64 = 1024 * 1024 * 1024;
    let ask = |bytes: u64, plan_max: &str| {
        let size = planned_size(bytes, Some(plan_max));
        (size, grown_disk_gib(size, Some(bytes), Some(plan_max)))
    };
    // cmux NEXT Pro (`lg`, 128 GiB at most): 48 GiB is `lg` (60 GiB of floor), grown to 72.
    assert_eq!(ask(48 * GIB, "lg"), (Some("lg"), Some(72)));
    // 60 GiB needs `xl` by the floor, past the plan: `lg` grown to 92 (90 rounded up).
    assert_eq!(ask(60 * GIB, "lg"), (Some("lg"), Some(92)));
    // 100 GiB: a 112 GiB floor within Pro's 128; half again is 150, capped at 128.
    assert_eq!(ask(100 * GIB, "lg"), (Some("lg"), Some(128)));
    // 120 GiB: a 132 GiB floor past Pro's 128: the size past the plan, refused with its upgrade.
    assert_eq!(ask(120 * GIB, "lg"), (Some("2xl"), None));
    // cmux NEXT Max (`2xl`, 256 GiB at most): 90 GiB is `xl` (102 of floor), grown to 136.
    assert_eq!(ask(90 * GIB, "2xl"), (Some("xl"), Some(136)));
    // 200 GiB: a 212 GiB floor past every size's own disk: `2xl` grown to 256 (300 capped).
    assert_eq!(ask(200 * GIB, "2xl"), (Some("2xl"), Some(256)));
    assert_eq!(ask(244 * GIB + 1, "2xl"), (None, None));
    assert_eq!(planned_size(244 * GIB + 1, Some("lg")), None);
    // Within the plan, small: the needed size, its own disk enough.
    assert_eq!(ask(10 * GIB, "lg"), (Some("md"), None));
    // A plan whose largest is `md` grows nothing: past its floor, the size the plan refuses.
    assert_eq!(ask(20 * GIB, "md"), (Some("md"), None));
    assert_eq!(ask(30 * GIB, "md"), (Some("lg"), None));
}

/// A grown disk is rounded up to 4 GiB, at most the plan's largest; no size, a size off the ladder or unknown bytes ask
/// nothing.
#[test]
fn a_grown_disk_rounds_up_to_four_gib_within_the_plan() {
    const GIB: u64 = 1024 * 1024 * 1024;
    assert_eq!(grown_disk_gib(Some("lg"), Some(45 * GIB), Some("lg")), Some(68));
    assert_eq!(grown_disk_gib(Some("2xl"), Some(100 * GIB), Some("2xl")), Some(152));
    // A size past the plan's disk grows nothing.
    assert_eq!(grown_disk_gib(Some("lg"), Some(50 * GIB), Some("md")), None);
    assert_eq!(grown_disk_gib(Some("2xl"), Some(120 * GIB), Some("lg")), None);
    // 80 GiB needs 120 GiB: `xl`'s own 128 holds it.
    assert_eq!(grown_disk_gib(Some("xl"), Some(80 * GIB), Some("2xl")), None);
    assert_eq!(grown_disk_gib(None, Some(50 * GIB), Some("lg")), None);
    assert_eq!(grown_disk_gib(Some("huge"), Some(50 * GIB), Some("lg")), None);
    assert_eq!(grown_disk_gib(Some("lg"), None, Some("lg")), None);
}

/// A start whose folder needs a larger size than the machine the platform answered (a workspace that already had an
/// `sm` machine): refused in the plan, so nothing is cloned or copied there, with the seed refusal the App reads as
/// "This folder is X, more than Y has room for". A disk at least the size's, a shape the platform did not name, and a
/// chat-size ask all go on as before.
mod machine_room {
    use std::cell::Cell;

    use serde_json::{Value, json};

    use super::super::super::plan_with_calls;
    use super::super::{GIB, MACHINE_TOO_SMALL, SEED_REFUSED};

    const FOLDER_BYTES: u64 = 10 * GIB;

    fn plan(size: Option<&str>, shape: Option<Value>, created: bool) -> (Value, usize) {
        plan_for(size, FOLDER_BYTES, None, shape, created)
    }

    fn plan_for(
        size: Option<&str>,
        bytes: u64,
        plan_max: Option<&str>,
        shape: Option<Value>,
        created: bool,
    ) -> (Value, usize) {
        let dir = tempfile::tempdir().unwrap();
        let ledger = dir.path().join("cloud-start-chat").join("destinations.json");
        let folder = dir.path().join("project");
        std::fs::create_dir(&folder).unwrap();
        let mut request = json!({"key": "0000000A-0000-4000-8000-0000000000F1", "account": "user-leo/",
            "loaded": false, "local": folder.to_str().unwrap(), "credential_on_stdin": true,
            "bytes": bytes});
        if let Some(size) = size {
            request["size"] = json!(size);
        }
        if let Some(plan_max) = plan_max {
            request["plan_max"] = json!(plan_max);
        }
        let ensures = Cell::new(0);
        let mut machine =
            json!({"provider": "cloud", "id": "vm_own", "name": "own-box", "state": "running"});
        if let Some(shape) = shape {
            machine["shape"] = shape;
        }
        let answer = plan_with_calls(
            &ledger,
            &request.to_string(),
            &mut "token\n".as_bytes(),
            &|_, _| {
                ensures.set(ensures.get() + 1);
                Ok(json!({"workspace": "own", "machine": machine.clone(), "created": created}))
            },
            &|_, _| panic!("no spare"),
        );
        (answer, ensures.get())
    }

    #[test]
    fn a_smaller_disk_than_the_size_asked_is_refused_before_any_copy_or_clone() {
        let (answer, ensures) =
            plan(Some("md"), Some(json!({"vcpu": 2, "memGiB": 4, "diskGiB": 16})), false);
        assert_eq!(ensures, 1);
        assert_eq!(answer["ok"], false, "the App copies or clones only after an ok plan: {answer}");
        assert_eq!(answer["error_code"], SEED_REFUSED, "{answer}");
        assert_eq!(answer["fallback_code"], MACHINE_TOO_SMALL, "{answer}");
        assert_eq!(answer["copy_bytes"], FOLDER_BYTES, "{answer}");
        assert_eq!(answer["room_bytes"], 4 * GIB, "{answer}");
        assert_eq!(answer["needed"], "md", "{answer}");
        assert_eq!(answer["machine_id"], "vm_own", "{answer}");
        assert_eq!(answer["machine_title"], "own-box", "{answer}");
        assert!(
            answer.get("size_locked").is_none(),
            "no plan upgrade helps a fixed machine: {answer}"
        );
        // Even one the platform says it made for this start, when it is smaller than asked.
        let (made, _) =
            plan(Some("md"), Some(json!({"vcpu": 2, "memGiB": 4, "diskGiB": 20})), true);
        assert_eq!(made["error_code"], SEED_REFUSED, "{made}");
    }

    /// A machine grown to a disk between two sizes is judged by the folder, not by the size's own disk: 10 GiB and the
    /// 12 GiB reserve fit 24 GiB, though `md` is 32.
    #[test]
    fn a_disk_between_sizes_with_room_for_the_folder_goes_on() {
        let (answer, _) =
            plan(Some("md"), Some(json!({"vcpu": 2, "memGiB": 4, "diskGiB": 24})), false);
        assert_eq!(answer["ok"], true, "{answer}");
        assert_eq!(answer["machine"], "vm_own", "{answer}");
    }

    /// The room check is the floor, never the half-again disk a start asks: a disk with room for the folder and the
    /// reserve goes on, one without is refused.
    #[test]
    fn a_disk_with_room_for_the_folder_and_the_reserve_goes_on() {
        // 10 GiB of folder and the 12 GiB reserve: 22 GiB.
        let (fits, _) =
            plan(Some("md"), Some(json!({"vcpu": 2, "memGiB": 4, "diskGiB": 22})), false);
        assert_eq!(fits["ok"], true, "{fits}");
        let (short, _) =
            plan(Some("md"), Some(json!({"vcpu": 2, "memGiB": 4, "diskGiB": 21})), false);
        assert_eq!(short["error_code"], SEED_REFUSED, "{short}");
        // 21 GiB less the reserve: 9 GiB of room.
        assert_eq!(short["room_bytes"], 9 * GIB, "{short}");
    }

    /// cmux NEXT Pro with a 45 GiB folder asks `lg` grown to 68 GiB; a platform that ignores `disk_gib` answers `lg`'s
    /// own 64 GiB, which holds the folder and the reserve (57 GiB): the start goes on, as it did before the half-again
    /// rule. With no plan known, one that falls short of the floor is refused.
    #[test]
    fn a_size_whose_own_disk_holds_the_floor_goes_on_when_the_grown_disk_is_ignored() {
        let (answer, _) = plan_for(
            Some("lg"),
            45 * GIB,
            Some("lg"),
            Some(json!({"vcpu": 8, "memGiB": 16, "diskGiB": 64})),
            true,
        );
        assert_eq!(answer["ok"], true, "{answer}");
        assert_eq!(answer["machine"], "vm_own", "{answer}");
        let (short, _) = plan_for(
            Some("lg"),
            60 * GIB,
            None,
            Some(json!({"vcpu": 8, "memGiB": 16, "diskGiB": 64})),
            true,
        );
        assert_eq!(short["error_code"], SEED_REFUSED, "{short}");
        assert_eq!(short["room_bytes"], 52 * GIB, "{short}");
    }

    /// cmux NEXT Pro with a 100 GiB folder asks `lg` grown to 128 GiB (no size within the plan holds its 112 GiB floor).
    /// A platform that ignores `disk_gib` makes `lg`'s own 64: the plan's size refusal naming `xl` and its upgrade, as
    /// the platform answers a start past the plan's sizes, never the machine too small. The grown disk goes on.
    #[test]
    fn a_plans_largest_size_made_below_the_floor_is_the_plans_size_refusal() {
        let (answer, _) = plan_for(
            Some("lg"),
            100 * GIB,
            Some("lg"),
            Some(json!({"vcpu": 8, "memGiB": 16, "diskGiB": 64})),
            true,
        );
        assert_eq!(answer["ok"], false, "{answer}");
        assert_eq!(answer["error_code"], "cloud.size.locked", "{answer}");
        assert_eq!(answer["size_locked"], json!({"needed": "xl", "allowed": "lg"}), "{answer}");
        assert_eq!(answer["copy_bytes"], 100 * GIB, "{answer}");
        assert_eq!(answer["retryable"], false, "{answer}");
        assert!(answer.get("fallback_code").is_none(), "{answer}");
        let (grown, _) = plan_for(
            Some("lg"),
            100 * GIB,
            Some("lg"),
            Some(json!({"vcpu": 8, "memGiB": 16, "diskGiB": 128})),
            true,
        );
        assert_eq!(grown["ok"], true, "{grown}");
        // A size within the plan that holds the floor stays the machine too small: no upgrade helps it.
        let (within, _) = plan_for(
            Some("lg"),
            48 * GIB,
            Some("2xl"),
            Some(json!({"vcpu": 8, "memGiB": 16, "diskGiB": 32})),
            true,
        );
        assert_eq!(within["error_code"], SEED_REFUSED, "{within}");
        // cmux NEXT Max's `2xl` made below the floor: no size above it, the machine too small.
        let (max, _) = plan_for(
            Some("2xl"),
            200 * GIB,
            Some("2xl"),
            Some(json!({"vcpu": 32, "memGiB": 64, "diskGiB": 128})),
            true,
        );
        assert_eq!(max["error_code"], SEED_REFUSED, "{max}");
    }

    #[test]
    fn an_equal_or_larger_disk_goes_on() {
        for disk in [32, 64] {
            let (answer, _) =
                plan(Some("md"), Some(json!({"vcpu": 4, "memGiB": 8, "diskGiB": disk})), false);
            assert_eq!(answer["ok"], true, "{answer}");
            assert_eq!(answer["machine"], "vm_own", "{answer}");
        }
        let (made, _) =
            plan(Some("md"), Some(json!({"vcpu": 4, "memGiB": 8, "diskGiB": 32})), true);
        assert_eq!(made["machine"], "vm_own", "{made}");
    }

    #[test]
    fn an_answer_with_no_shape_goes_on_as_before() {
        let (answer, _) = plan(Some("md"), None, false);
        assert_eq!(answer["ok"], true, "{answer}");
        assert_eq!(answer["machine"], "vm_own", "{answer}");
    }

    #[test]
    fn a_chat_size_ask_is_not_checked() {
        for size in [Some("sm"), None] {
            let (answer, _) =
                plan(size, Some(json!({"vcpu": 1, "memGiB": 2, "diskGiB": 8})), false);
            assert_eq!(answer["ok"], true, "{answer}");
            assert_eq!(answer["machine"], "vm_own", "{answer}");
        }
    }

    /// A send pinned to a machine (a retry) whose disk the App's list names smaller than the size asked is refused
    /// the same way; a listed disk at the size's, or none named, goes on.
    #[test]
    fn a_pinned_machine_smaller_than_the_size_asked_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let ledger = dir.path().join("cloud-start-chat").join("destinations.json");
        let key = "0000000A-0000-4000-8000-0000000000F2";
        assert_eq!(
            super::super::super::pin(&ledger, key, "user-leo/team-a", "vm_pinned", None)["ok"],
            true
        );
        let retry = |disk_mb: Option<u64>| {
            let mut machine = json!({"id": "vm_pinned", "title": "cloud-chats"});
            if let Some(disk_mb) = disk_mb {
                machine["disk_mb"] = json!(disk_mb);
            }
            let request = json!({"key": key, "account": "user-leo/team-a", "loaded": true,
                "machines": [machine], "size": "md", "bytes": FOLDER_BYTES});
            super::super::super::plan(&ledger, &request.to_string())
        };
        let small = retry(Some(16_384));
        assert_eq!(small["error_code"], SEED_REFUSED, "{small}");
        assert_eq!(small["machine_title"], "cloud-chats", "{small}");
        assert_eq!(retry(Some(32_768))["machine"], "vm_pinned");
        assert_eq!(retry(None)["machine"], "vm_pinned");
    }
}
