//! `cmux browser open-diff-viewer --path <dir>` against a fake app socket
//! (cx-ae75 follow-up): a relative `--path` names a folder of the caller's
//! working directory, so the app (whose own working directory is elsewhere)
//! must get it absolute. An agent runs `--path .` from its project folder.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// Runs `cmux <args>` in `cwd` against a fake app that answers every
/// request `ok` and records it; returns the recorded `action.run` params.
fn action_run_params(args: &[&str], cwd: &Path) -> Value {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir: PathBuf =
        Path::new("/tmp").join(format!("cmux-actpath-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let done = Arc::new(AtomicBool::new(false));
    let received = Arc::new(Mutex::new(Vec::<Value>::new()));
    let app = {
        let (done, received) = (done.clone(), received.clone());
        std::thread::spawn(move || {
            loop {
                match listener.accept() {
                    Ok((stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
                        let mut reader = BufReader::new(stream.try_clone().unwrap());
                        let mut writer = stream;
                        let mut line = String::new();
                        while reader.read_line(&mut line).unwrap_or(0) > 0 {
                            let request: Value = serde_json::from_str(&line).unwrap();
                            line.clear();
                            let response = json!({"id": request["id"], "ok": true, "result": {"ran": true, "created": []}});
                            received.lock().unwrap().push(request);
                            if writeln!(writer, "{response}").is_err() {
                                break;
                            }
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        if done.load(Ordering::Relaxed) {
                            break;
                        }
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => panic!("app accept: {error}"),
                }
            }
        })
    };
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("--app-socket")
        .arg(&socket)
        .args(args)
        .current_dir(cwd)
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    done.store(true, Ordering::Relaxed);
    app.join().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let received = received.lock().unwrap();
    let run = received
        .iter()
        .find(|request| request["method"] == "action.run")
        .unwrap_or_else(|| panic!("no action.run sent: {received:?}"));
    run["params"].clone()
}

fn project() -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = std::env::temp_dir().join(format!("cmux-actpath-project-{stamp}"));
    std::fs::create_dir_all(dir.join("sub")).unwrap();
    dir.canonicalize().unwrap()
}

#[test]
fn a_relative_diff_path_reaches_the_app_as_the_callers_folder() {
    let project = project();
    let params = action_run_params(&["browser", "open-diff-viewer", "--path", "."], &project);
    assert_eq!(params["args"]["path"], json!(project.to_string_lossy()), "{params}");
    let params = action_run_params(&["browser", "open-diff-viewer", "--path=sub"], &project);
    assert_eq!(params["args"]["path"], json!(project.join("sub").to_string_lossy()), "{params}");
    let _ = std::fs::remove_dir_all(&project);
}

#[test]
fn an_absolute_diff_path_is_sent_unchanged() {
    let project = project();
    let params = action_run_params(&["browser", "open-diff-viewer", "--path", "/tmp"], &project);
    assert_eq!(params["args"]["path"], json!("/tmp"), "{params}");
    let _ = std::fs::remove_dir_all(&project);
}

/// Never merge (#35413 coordinator request): the test
/// `a_relative_diff_path_reaches_the_app_as_the_callers_folder`
/// 50 times in this process under synthetic load (`stress50::run`).
#[test]
fn stress50_a_relative_diff_path_reaches_the_app_as_the_callers_folder() {
    stress50::run(
        "a_relative_diff_path_reaches_the_app_as_the_callers_folder",
        a_relative_diff_path_reaches_the_app_as_the_callers_folder,
    );
}

/// Never merge (#35413 coordinator request): the helper of this file's
/// stress50_ wrapper (branches test/rds-stress50-{head,base}-never-merge).
mod stress50 {
    use std::cell::RefCell;
    use std::io::Write;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    const RUNS: usize = 50;

    thread_local! {
        /// Where this thread's last panic happened (file:line).
        static PANIC_AT: RefCell<Option<String>> = const { RefCell::new(None) };
    }

    /// Runs `test` 50 times in this process, each run inside `catch_unwind`,
    /// while synthetic load like a full suite run is on: one thread per CPU
    /// (`available_parallelism`) spins the CPU for about 1 ms, then writes and
    /// syncs (`sync_all`) a 64 KiB file in a temp folder, until the runs end.
    /// Each run prints one line on stderr. Fails with
    /// "<name>: F of 50 failed: <first 3 messages>" when a run failed.
    pub(super) fn run(name: &str, test: fn()) {
        let previous_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let at = info.location().map(|at| format!("{}:{}", at.file(), at.line()));
            let _ = PANIC_AT.try_with(|slot| {
                if let Ok(mut slot) = slot.try_borrow_mut() {
                    *slot = at;
                }
            });
            previous_hook(info);
        }));
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let folder =
            std::env::temp_dir().join(format!("rds-stress50-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let threads = std::thread::available_parallelism().map_or(4, |count| count.get());
        let load: Vec<_> = (0..threads)
            .map(|index| {
                let (stop, path) = (stop.clone(), folder.join(format!("load-{index}")));
                std::thread::spawn(move || {
                    let block = vec![0x5a_u8; 64 * 1024];
                    while !stop.load(Ordering::Relaxed) {
                        let spin = Instant::now();
                        while spin.elapsed() < Duration::from_millis(1) {
                            std::hint::spin_loop();
                        }
                        if let Ok(mut file) = std::fs::File::create(&path) {
                            let _ = file.write_all(&block);
                            let _ = file.sync_all();
                        }
                    }
                })
            })
            .collect();
        let started = Instant::now();
        let mut failures: Vec<String> = Vec::new();
        for attempt in 1..=RUNS {
            PANIC_AT.with(|slot| *slot.borrow_mut() = None);
            let run_started = Instant::now();
            let result = std::panic::catch_unwind(test);
            let took = run_started.elapsed();
            let Err(payload) = result else {
                eprintln!("stress50 {name}: run {attempt} of {RUNS} passed in {took:?}");
                continue;
            };
            let text = payload
                .downcast_ref::<&str>()
                .map(|text| (*text).to_string())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "a panic without a text payload".to_string());
            let at = PANIC_AT.with(|slot| slot.borrow_mut().take()).unwrap_or_default();
            let message: String = format!("run {attempt} at {at}: {}", text.replace('\n', " "))
                .chars()
                .take(600)
                .collect();
            eprintln!("stress50 {name}: run {attempt} of {RUNS} FAILED in {took:?}: {message}");
            failures.push(message);
        }
        stop.store(true, Ordering::Relaxed);
        for thread in load {
            let _ = thread.join();
        }
        let _ = std::fs::remove_dir_all(&folder);
        eprintln!(
            "stress50 {name}: {} of {RUNS} failed, in {:?}, beside {threads} load threads",
            failures.len(),
            started.elapsed()
        );
        assert!(
            failures.is_empty(),
            "{name}: {} of {RUNS} failed: {}",
            failures.len(),
            failures[..failures.len().min(3)].join(" || ")
        );
    }
}
