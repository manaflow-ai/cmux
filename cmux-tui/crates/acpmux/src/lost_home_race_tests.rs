//! Forced races for the writers under the home. Each writer checks the home it holds
//! (`config::refuse_lost_home`), then writes. A home replaced after the check passed and before
//! the write must not get the write: the writer goes through the folder this daemon locked
//! (`config::hold_home`, `home_fs`), so the write lands in the folder that was moved away, or
//! nowhere. Each test holds its writer at the end of that check (`config::seams::on_checked`),
//! asserts the check passed there, replaces the home, lets the writer go on, and asserts the new
//! home holds nothing the writer made (and, for a removal, lost nothing).
//!
//! The held home is process-wide, so each test runs its body in a process of its own
//! ([`isolated`]): the test binary, filtered to that one test.
//!
//! The forced races run on Unix only: they prove a write goes through the held folder's
//! descriptor, and Windows has no `*at` calls. There each `home_fs` step goes by path after
//! checking the home's file id again, which
//! [`a_replaced_home_is_refused_by_its_file_id_and_the_same_home_passes`] covers.

use std::path::{Path, PathBuf};
use std::sync::{Condvar, Mutex};
use std::time::Duration;

/// The test a child process runs: its full name.
const ROLE: &str = "ACPMUX_HOME_RACE_TEST";

/// Runs `body` in a process of its own with `ACPMUX_HOME` a fresh home under a scratch folder,
/// then `after` in this process with that home and the child's stdout. `module` is the caller's
/// `module_path!()`, `name` its test function.
pub(crate) fn isolated(
    module: &str,
    name: &str,
    body: impl FnOnce(&Path),
    after: impl FnOnce(&Path, &str),
) {
    let module = module.split_once("::").map_or("", |(_, rest)| rest);
    let full = format!("{module}::{name}");
    if std::env::var(ROLE).ok().as_deref() == Some(full.as_str()) {
        let home = PathBuf::from(std::env::var("ACPMUX_HOME").unwrap());
        body(&home);
        return;
    }
    let dir = std::env::temp_dir().join(format!("amx-race-{name}-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let dir = std::fs::canonicalize(&dir).unwrap();
    let home = dir.join("h");
    std::fs::create_dir(&home).unwrap();
    let out = std::process::Command::new(std::env::current_exe().unwrap())
        .args([full.as_str(), "--exact", "--nocapture", "--test-threads=1"])
        .env(ROLE, &full)
        .env("ACPMUX_HOME", &home)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    // The filter selected this one test; it may end its process itself (an interrupted save).
    let ran = out.status.success() && stdout.contains("running 1 test");
    let finished = ran.then(|| after(&home, &stdout));
    let _ = std::fs::remove_dir_all(&dir);
    assert!(finished.is_some(), "{full}: {stdout}\n{}", String::from_utf8_lossy(&out.stderr));
}

/// `home` is moved to `home.old` and a new folder is made at `home`.
pub(crate) fn replace(home: &Path) {
    std::fs::rename(home, home.with_extension("old")).unwrap();
    std::fs::create_dir(home).unwrap();
}

/// Every name below `dir`, folders too, relative to it and sorted.
pub(crate) fn tree(dir: &Path) -> Vec<String> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<String>) {
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            out.push(path.strip_prefix(root).unwrap().to_string_lossy().into_owned());
            if path.is_dir() && !path.is_symlink() {
                walk(root, &path, out);
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, dir, &mut out);
    out.sort();
    out
}

/// A copy of the tree at `from` made at `to`: a seed for a new home restored from the old one,
/// so a writer that reads the new home by path and writes the held one finds the same state in
/// both, and a write by path would change the new home.
pub(crate) fn copy_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let (path, target) = (entry.path(), to.join(entry.file_name()));
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&path, &target);
        } else {
            std::fs::copy(&path, &target).unwrap();
        }
    }
}

/// The held check: whether it passed, and whether the test let it go on; and the writer's
/// signal that it reached the hold, or the test's that it may go on.
type Hold = std::sync::Arc<(Mutex<(Option<bool>, bool)>, Condvar)>;

/// The writer thread's `seams::on_checked` hook: holds the first check of `target`, when it
/// passed, until the test lets it go on. Every other check goes on.
fn at_check(hold: &Hold, target: &Path, path: &Path, passed: bool) {
    if path != target {
        return;
    }
    let (held, moved) = &**hold;
    let mut held = held.lock().unwrap();
    if held.0.is_some() {
        return;
    }
    held.0 = Some(passed);
    moved.notify_all();
    if passed {
        let _released = moved.wait_while(held, |held| !held.1).unwrap();
    }
}

/// The race, in the child: the daemon holds `home`, `write` runs on a thread of its own and is
/// held at the end of its check of `target`, which must have passed; the home is replaced and
/// `seed` fills the new one (another daemon's files); then the writer goes on. The new home
/// must hold exactly what `seed` made, and `kept` (relative to the home) must be in the folder
/// that was moved away: the write went through the folder this daemon locked. The hook is the
/// writer thread's own, so the check must run on that thread.
pub(crate) fn forced(
    home: &Path,
    target: PathBuf,
    seed: impl FnOnce(&Path),
    kept: Option<&str>,
    write: impl FnOnce() + Send + 'static,
) {
    crate::config::hold_home();
    let hold: Hold = Default::default();
    let writer = {
        let (hold, target) = (hold.clone(), target.clone());
        std::thread::spawn(move || {
            let _hook = crate::config::seams::on_checked(move |path, passed| {
                at_check(&hold, &target, path, passed)
            });
            write();
        })
    };
    let (held, moved) = &*hold;
    // timeout: only a writer that never checks `target` ends here; the order is the hook's.
    let (held, waited) = moved
        .wait_timeout_while(held.lock().unwrap(), Duration::from_secs(120), |held| held.0.is_none())
        .unwrap();
    assert!(!waited.timed_out(), "the writer never checked {}", target.display());
    // The hold point is reached in the state this test names: the check passed, before the
    // replacement. A writer whose check already failed would prove nothing here.
    assert_eq!(held.0, Some(true), "the writer was not held past its check");
    drop(held);
    replace(home);
    seed(home);
    let seeded = tree(home);
    {
        let (held, moved) = &*hold;
        held.lock().unwrap().1 = true;
        moved.notify_all();
    }
    writer.join().unwrap();
    assert_eq!(tree(home), seeded, "the held writer changed the new home");
    if let Some(kept) = kept {
        let old = home.with_extension("old").join(kept);
        assert!(old.exists(), "the write did not land in the held folder: {}", old.display());
    }
}

pub(crate) fn nothing(_: &Path) {}

#[cfg(unix)]
#[test]
fn write_atomic_held_past_its_check() {
    isolated(
        module_path!(),
        "write_atomic_held_past_its_check",
        |home| {
            let path = home.join("x.json");
            forced(home, path.clone(), nothing, Some("x.json"), move || {
                let _ = crate::config::write_atomic(&path, b"{}");
            });
        },
        |_, _| {},
    );
}

#[cfg(unix)]
#[test]
fn a_private_state_dir_held_past_its_check() {
    isolated(
        module_path!(),
        "a_private_state_dir_held_past_its_check",
        |home| {
            let dir = home.join("state").join("inner");
            forced(home, dir.clone(), nothing, Some("state/inner"), move || {
                let _ = crate::config::private_state_dir(&dir);
            });
        },
        |_, _| {},
    );
}

#[cfg(unix)]
#[test]
fn a_private_state_append_held_past_its_check() {
    isolated(
        module_path!(),
        "a_private_state_append_held_past_its_check",
        |home| {
            let path = home.join("daemon.log");
            forced(home, path.clone(), nothing, Some("daemon.log"), move || {
                use std::io::Write as _;
                let _ = crate::config::private_state_append(&path)
                    .and_then(|mut file| Ok(file.write_all(b"line\n")?));
            });
        },
        |_, _| {},
    );
}

/// An event segment the store opens to append, its folder there in both homes.
#[cfg(unix)]
#[test]
fn a_store_segment_append_held_past_its_check() {
    isolated(
        module_path!(),
        "a_store_segment_append_held_past_its_check",
        |home| {
            std::fs::create_dir(home.join("events")).unwrap();
            let path = home.join("events").join("000001.ndjson");
            let seed = |home: &Path| std::fs::create_dir(home.join("events")).unwrap();
            forced(home, path.clone(), seed, Some("events/000001.ndjson"), move || {
                use std::io::Write as _;
                let _ = crate::store::open_private_append(&path)
                    .and_then(|mut file| Ok(file.write_all(b"line\n")?));
            });
        },
        |_, _| {},
    );
}

/// The chat index saves its cache (`chat-index/v1.json`) as it starts.
#[cfg(unix)]
#[test]
fn the_chat_index_cache_held_past_its_check() {
    isolated(
        module_path!(),
        "the_chat_index_cache_held_past_its_check",
        |home| {
            let user = home.parent().unwrap().join("user");
            std::fs::create_dir_all(&user).unwrap();
            let sources = crate::chats::ChatSources {
                home: user,
                acpmux_home: home.to_path_buf(),
                env: std::sync::Arc::new(|_| None),
                launch_roots: Vec::new(),
                user_roots: Vec::new(),
            };
            let target = home.join("chat-index").join("v1.json");
            forced(home, target, nothing, Some("chat-index/v1.json"), move || {
                drop(crate::chats::ChatService::start(sources));
            });
        },
        |_, _| {},
    );
}

/// The ACP registry's saved copy (`acp-registry/registry.json`).
#[cfg(unix)]
#[test]
fn the_registry_copy_held_past_its_check() {
    isolated(
        module_path!(),
        "the_registry_copy_held_past_its_check",
        |home| {
            let owned = home.to_path_buf();
            let target = crate::registry::cache_dir(home);
            forced(home, target, nothing, Some("acp-registry"), move || {
                let _ = crate::registry::save(&owned, br#"{"agents": []}"#);
            });
        },
        |_, _| {},
    );
}

/// A removed route's backup goes to `<home>/route-backups`, moved there from the routes folder.
#[cfg(unix)]
#[test]
fn a_route_backup_held_past_its_check() {
    isolated(
        module_path!(),
        "a_route_backup_held_past_its_check",
        |home| {
            let routes = home.parent().unwrap().join("routes");
            let file = crate::routes::file_from_json(&serde_json::json!({
                "kind": "subrouter", "anthropicBaseUrl": "http://127.0.0.1:9/a"
            }))
            .unwrap();
            crate::routes::add(Some(&routes), "proxy-a", &file, false).unwrap();
            let owned = home.to_path_buf();
            let target = home.join("route-backups");
            forced(home, target, nothing, Some("route-backups"), move || {
                let _ = crate::routes::remove(Some(&routes), &owned, "proxy-a");
            });
        },
        |_, _| {},
    );
}

/// The web listener's record (`listener.json`).
#[cfg(unix)]
#[test]
fn the_listener_record_held_past_its_check() {
    isolated(
        module_path!(),
        "the_listener_record_held_past_its_check",
        |home| {
            let owned = home.to_path_buf();
            let target = home.join(crate::listener_record::FILE_NAME);
            forced(home, target, nothing, Some(crate::listener_record::FILE_NAME), move || {
                // Kept: the record's drop removes it, which is not the write under test.
                if let Ok(written) =
                    crate::listener_record::write(&owned, "127.0.0.1:9".parse().unwrap())
                {
                    std::mem::forget(written);
                }
            });
        },
        |_, _| {},
    );
}

/// The folder for agents no person asked for (`<home>/unattended`).
#[cfg(unix)]
#[test]
fn the_unattended_folder_held_past_its_check() {
    isolated(
        module_path!(),
        "the_unattended_folder_held_past_its_check",
        |home| {
            let owned = home.to_path_buf();
            let target = home.join("unattended");
            forced(home, target, nothing, Some("unattended"), move || {
                let _ = crate::protected_folders::unattended_cwd_in(&owned, None);
            });
        },
        |_, _| {},
    );
}

/// A workspace's display number (`agent-displays/`).
#[cfg(unix)]
#[test]
fn an_agent_display_held_past_its_check() {
    isolated(
        module_path!(),
        "an_agent_display_held_past_its_check",
        |home| {
            let dir = home.join("agent-displays");
            forced(home, dir.clone(), nothing, Some("agent-displays/lock"), move || {
                let _ = crate::agent_displays::display_for(&dir, "ws-a");
            });
        },
        |_, _| {},
    );
}

/// A file an agent's tools read (`agent_tools::write_private`).
#[cfg(unix)]
#[test]
fn an_agent_tools_file_held_past_its_check() {
    isolated(
        module_path!(),
        "an_agent_tools_file_held_past_its_check",
        |home| {
            let path = home.join("agent-tools").join("x.json");
            forced(home, path.clone(), nothing, Some("agent-tools/x.json"), move || {
                let _ = crate::agent_tools::write_private(&path, b"{}");
            });
        },
        |_, _| {},
    );
}

/// A preset's system prompt file (`presets/<name>/`).
#[cfg(unix)]
#[test]
fn a_preset_prompt_held_past_its_check() {
    isolated(
        module_path!(),
        "a_preset_prompt_held_past_its_check",
        |home| {
            let presets = home.join("presets");
            let kept = format!("presets/p/{}", crate::config::SYSTEM_PROMPT_FILE);
            forced(home, presets.clone(), nothing, Some(&kept), move || {
                let _ = crate::config::write_system_prompt(&presets, "p", "be brief");
            });
        },
        |_, _| {},
    );
}

/// A removal: a preset's folder is removed from the held home, never from the new one.
#[cfg(unix)]
#[test]
fn a_preset_removal_held_past_its_check() {
    isolated(
        module_path!(),
        "a_preset_removal_held_past_its_check",
        |home| {
            let presets = home.join("presets");
            std::fs::create_dir_all(presets.join("p")).unwrap();
            std::fs::write(presets.join("p").join("prompt"), "mine").unwrap();
            let seed = |home: &Path| {
                std::fs::create_dir_all(home.join("presets").join("p")).unwrap();
                std::fs::write(home.join("presets").join("p").join("prompt"), "theirs").unwrap();
            };
            forced(home, presets.clone(), seed, None, move || {
                let _ = crate::config::remove_preset_dir(&presets, "p");
            });
            assert!(
                !home.with_extension("old").join("presets").join("p").exists(),
                "the held home's preset was not removed"
            );
        },
        |_, _| {},
    );
}

/// The models an ACP agent named (`acp-models/`).
#[cfg(unix)]
#[test]
fn an_acp_models_list_held_past_its_check() {
    isolated(
        module_path!(),
        "an_acp_models_list_held_past_its_check",
        |home| {
            let dir = home.join("acp-models");
            forced(home, dir.clone(), nothing, Some("acp-models/agent.json"), move || {
                let cache = crate::live_models::AcpCache::new(dir);
                let _ = cache.store("agent", "profile", &[("m".to_owned(), "M".to_owned())]);
            });
        },
        |_, _| {},
    );
}

/// The host's sender token (`sender-token`), made at the daemon's start: written to a temporary
/// file and hard-linked into place. A replaced home never gets this host's token (#41372 review
/// F1): a sender holding the new home's file would be verified by it.
#[cfg(unix)]
#[test]
fn the_sender_token_held_past_its_check() {
    isolated(
        module_path!(),
        "the_sender_token_held_past_its_check",
        |home| {
            let owned = home.to_path_buf();
            let target = crate::sender_token::path_in(home);
            forced(home, target, nothing, Some(crate::sender_token::FILE), move || {
                let _ = crate::sender_token::ensure(&owned);
            });
        },
        |_, _| {},
    );
}

/// `home_fs::remove_dir_all` under the held home removes a symlink itself (never what it names)
/// and refuses a file that is not a folder, keeping it, as `std::fs::remove_dir_all` does
/// (#41372 review F4).
#[cfg(unix)]
#[test]
fn removing_a_tree_refuses_a_file_and_removes_only_a_link() {
    isolated(
        module_path!(),
        "removing_a_tree_refuses_a_file_and_removes_only_a_link",
        |home| {
            crate::config::hold_home();
            let file = home.join("a-file");
            std::fs::write(&file, b"kept").unwrap();
            let removed = crate::home_fs::remove_dir_all(&file);
            assert!(removed.is_err(), "a file was removed as a tree: {removed:?}");
            assert_eq!(std::fs::read(&file).unwrap(), b"kept", "the file was not kept");
            let target = home.join("named");
            std::fs::create_dir(&target).unwrap();
            std::fs::write(target.join("inside"), b"kept").unwrap();
            let link = home.join("link");
            std::os::unix::fs::symlink(&target, &link).unwrap();
            crate::home_fs::remove_dir_all(&link).expect("a symlink is removed");
            assert!(std::fs::symlink_metadata(&link).is_err(), "the symlink stayed");
            assert!(target.join("inside").exists(), "the symlink was followed");
        },
        |_, _| {},
    );
}

/// Windows (and any platform): a writer under the held home checks the home's identity again
/// right before each step (`home_fs`; on Windows the file id, its volume serial and file index).
/// The same home passes; a replaced one is refused and gets nothing.
#[test]
fn a_replaced_home_is_refused_by_its_file_id_and_the_same_home_passes() {
    isolated(
        module_path!(),
        "a_replaced_home_is_refused_by_its_file_id_and_the_same_home_passes",
        |home| {
            crate::config::hold_home();
            crate::config::write_atomic(&home.join("a.json"), b"{}")
                .expect("the held home itself is written");
            replace(home);
            let wrote = crate::config::write_atomic(&home.join("b.json"), b"{}");
            assert!(wrote.is_err(), "a replaced home was written: {wrote:?}");
            assert_eq!(tree(home), Vec::<String>::new(), "the new home got a write");
        },
        |_, _| {},
    );
}

/// The permission bits of `path` itself (never through a link).
#[cfg(unix)]
fn mode_of(path: &Path) -> u32 {
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::symlink_metadata(path).unwrap().permissions().mode() & 0o7777
}

/// #41462 review F1: under umask 022, a `home_fs` copy of a 0600 file and a `home_fs` write are
/// never readable by others, at any point: the hook stats each one once part of its bytes are
/// written, then fails it there (as a full disk would). No partial file is left. Whole, the copy
/// has its source's mode and the write 0600; a folder made is 0700. Each holds under the held
/// home and outside it (`native::restore_in` copies outside it). The umask is process-wide, so
/// this runs in a process of its own ([`isolated`]).
#[cfg(unix)]
#[test]
fn a_copy_or_write_never_shows_its_bytes_to_others() {
    isolated(
        module_path!(),
        "a_copy_or_write_never_shows_its_bytes_to_others",
        |home| {
            use std::cell::RefCell;
            use std::os::unix::fs::PermissionsExt as _;
            use std::rc::Rc;
            // SAFETY: umask has no preconditions; this process runs this one test.
            unsafe { libc::umask(0o022) };
            crate::config::hold_home();
            let outside = home.with_extension("outside");
            std::fs::create_dir(&outside).unwrap();
            for dir in [home.to_path_buf(), outside] {
                let source = dir.join("transcript");
                std::fs::write(&source, vec![7u8; 256 << 10]).unwrap();
                std::fs::set_permissions(&source, std::fs::Permissions::from_mode(0o600)).unwrap();
                let before = tree(&dir);
                let seen: Rc<RefCell<Vec<(PathBuf, u32)>>> = Rc::default();
                {
                    let seen = seen.clone();
                    let _fail = crate::config::seams::on_mid_write(move |path| {
                        seen.borrow_mut().push((path.to_path_buf(), mode_of(path)));
                        Err(std::io::Error::other("forced: the disk is full"))
                    });
                    let copied = crate::home_fs::copy(&source, dir.join("copy"));
                    assert!(copied.is_err(), "the copy never failed midway: {copied:?}");
                    let written = crate::home_fs::write(dir.join("written"), vec![1u8; 256 << 10]);
                    assert!(written.is_err(), "the write never failed midway: {written:?}");
                }
                let seen = seen.take();
                assert_eq!(seen.len(), 2, "each write stopped once, midway: {seen:?}");
                for (path, mode) in &seen {
                    assert_eq!(mode & 0o077, 0, "{} was {mode:o} while written", path.display());
                }
                assert_eq!(tree(&dir), before, "a failed write left a file in {}", dir.display());
                crate::home_fs::copy(&source, dir.join("copy")).unwrap();
                assert_eq!(mode_of(&dir.join("copy")), 0o600, "the copy's mode");
                crate::home_fs::write(dir.join("written"), b"whole").unwrap();
                assert_eq!(mode_of(&dir.join("written")), 0o600, "the write's mode");
                crate::home_fs::create_dir(dir.join("made"), 0o755).unwrap();
                assert_eq!(mode_of(&dir.join("made")), 0o700, "the folder's mode");
            }
        },
        |_, _| {},
    );
}

/// #41721 review F1: `home_fs::symlink_metadata` and `try_exists_nofollow` read the held home,
/// not a replacement at its path, and give what `std::fs::symlink_metadata` gives there (the same
/// file, its length and times, a symlink itself never followed); a name in neither home is
/// `Ok(false)`.
#[cfg(unix)]
#[test]
fn a_metadata_read_reads_the_held_home_not_its_replacement() {
    isolated(
        module_path!(),
        "a_metadata_read_reads_the_held_home_not_its_replacement",
        |home| {
            use std::os::unix::fs::MetadataExt as _;
            let dir = home.join("sessions").join("c");
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("cold.zst"), b"archive").unwrap();
            std::os::unix::fs::symlink("nowhere", dir.join("link")).unwrap();
            crate::config::hold_home();
            let want = std::fs::symlink_metadata(dir.join("cold.zst")).unwrap();
            let got = crate::home_fs::symlink_metadata(dir.join("cold.zst")).unwrap();
            assert_eq!(
                (got.dev(), got.ino(), got.len(), got.mode(), got.mtime(), got.mtime_nsec()),
                (want.dev(), want.ino(), want.len(), want.mode(), want.mtime(), want.mtime_nsec()),
            );
            assert_eq!(got.created().ok(), want.created().ok(), "the birth time");
            let link = crate::home_fs::symlink_metadata(dir.join("link")).unwrap();
            assert!(link.file_type().is_symlink(), "a symlink is read itself, never followed");
            replace(home);
            std::fs::create_dir_all(home.join("sessions").join("c")).unwrap();
            assert!(
                crate::home_fs::try_exists_nofollow(dir.join("cold.zst")).unwrap(),
                "the held home's archive, though the replacement has none"
            );
            let held = crate::home_fs::symlink_metadata(dir.join("cold.zst")).unwrap();
            assert_eq!(held.ino(), want.ino(), "the held home's file");
            assert!(!crate::home_fs::try_exists_nofollow(dir.join("none")).unwrap());
            assert!(!crate::home_fs::try_exists_nofollow(home.join("no").join("such")).unwrap());
        },
        |_, _| {},
    );
}
