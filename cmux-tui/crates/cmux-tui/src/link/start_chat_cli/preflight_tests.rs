//! A Cloud start's folder check before any machine: every absolute folder goes on, whatever its
//! size, a parent of repositories past the copy's limits (`~/Projects`) above all, and its answer
//! carries the copy's estimate and decision, made before any machine exists.

use std::path::Path;

use super::super::super::sync_cli::size_cap;
use super::{grown_disk_gib, needed_disk, needed_size, run};

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

/// The needed disk is half again the folder, and at least the folder and the 12 GiB reserve: the reserve decides up to
/// 24 GiB of folder, the half above it.
#[test]
fn the_needed_disk_is_half_again_the_folder_and_at_least_the_reserve() {
    const GIB: u64 = 1024 * 1024 * 1024;
    assert_eq!(needed_disk(0), 12 * GIB);
    assert_eq!(needed_disk(4 * GIB), 16 * GIB);
    assert_eq!(needed_disk(24 * GIB), 36 * GIB);
    assert_eq!(needed_disk(40 * GIB), 60 * GIB);
    // Half a byte rounds up.
    assert_eq!(needed_disk(40 * GIB + 1), 60 * GIB + 2);
    assert_eq!(needed_disk(u64::MAX), u64::MAX);
}

#[test]
fn the_needed_size_is_the_smallest_disk_with_room_for_the_needed_disk() {
    const GIB: u64 = 1024 * 1024 * 1024;
    assert_eq!(needed_size(0), Some("sm"));
    assert_eq!(needed_size(4 * GIB), Some("sm"));
    assert_eq!(needed_size(4 * GIB + 1), Some("md"));
    assert_eq!(needed_size(20 * GIB), Some("md"));
    assert_eq!(needed_size(20 * GIB + 1), Some("lg"));
    // 64 GiB holds two thirds of itself: 42 GiB and a bit, no longer the 52 the reserve alone left.
    assert_eq!(needed_size(42 * GIB), Some("lg"));
    assert_eq!(needed_size(43 * GIB), Some("xl"));
    assert_eq!(needed_size(52 * GIB), Some("xl"));
    assert_eq!(needed_size(85 * GIB), Some("xl"));
    assert_eq!(needed_size(86 * GIB), None);
    assert_eq!(needed_size(u64::MAX), None);
}

/// A folder past its size's own disk asks that size grown to its needed disk, rounded up to 4 GiB; one the size holds,
/// no size, a size off the ladder or unknown bytes ask nothing.
#[test]
fn a_folder_past_its_sizes_disk_asks_the_disk_grown_to_four_gib() {
    const GIB: u64 = 1024 * 1024 * 1024;
    // 50 GiB needs 75 GiB: `lg` (64) grows to 76.
    assert_eq!(grown_disk_gib(Some("lg"), Some(50 * GIB)), Some(76));
    // 100 GiB needs 150 GiB: `2xl` (128) grows to 152.
    assert_eq!(grown_disk_gib(Some("2xl"), Some(100 * GIB)), Some(152));
    // 80 GiB needs 120 GiB: `xl`'s own 128 holds it.
    assert_eq!(grown_disk_gib(Some("xl"), Some(80 * GIB)), None);
    assert_eq!(grown_disk_gib(Some("lg"), Some(40 * GIB)), None);
    assert_eq!(grown_disk_gib(None, Some(50 * GIB)), None);
    assert_eq!(grown_disk_gib(Some("huge"), Some(50 * GIB)), None);
    assert_eq!(grown_disk_gib(Some("lg"), None), None);
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
        let dir = tempfile::tempdir().unwrap();
        let ledger = dir.path().join("cloud-start-chat").join("destinations.json");
        let folder = dir.path().join("project");
        std::fs::create_dir(&folder).unwrap();
        let mut request = json!({"key": "0000000A-0000-4000-8000-0000000000F1", "account": "user-leo/",
            "loaded": false, "local": folder.to_str().unwrap(), "credential_on_stdin": true,
            "bytes": FOLDER_BYTES});
        if let Some(size) = size {
            request["size"] = json!(size);
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

    /// A machine grown past its size's disk (`disk_gib`) has room when it holds the folder's needed disk, and is
    /// refused when the platform made the size's own disk (one that ignores `disk_gib`).
    #[test]
    fn a_grown_disk_with_room_for_the_needed_disk_goes_on() {
        // 10 GiB of folder needs 22 GiB: 12 GiB of reserve, more than half again.
        let (fits, _) =
            plan(Some("md"), Some(json!({"vcpu": 2, "memGiB": 4, "diskGiB": 22})), false);
        assert_eq!(fits["ok"], true, "{fits}");
        let (short, _) =
            plan(Some("md"), Some(json!({"vcpu": 2, "memGiB": 4, "diskGiB": 21})), false);
        assert_eq!(short["error_code"], SEED_REFUSED, "{short}");
        // 21 GiB less the reserve: 9 GiB of room.
        assert_eq!(short["room_bytes"], 9 * GIB, "{short}");
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
