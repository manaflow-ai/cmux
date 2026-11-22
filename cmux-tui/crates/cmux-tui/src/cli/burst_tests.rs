use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;

use super::*;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

fn run_of(list: &[&str]) -> Burst {
    match parse(&words(list)) {
        Ok(Parsed::Run(burst)) => burst,
        other => panic!("{list:?}: {other:?}"),
    }
}

#[test]
fn burst_parse_takes_the_command_after_the_dashes() {
    let burst = run_of(&["--", "cargo", "test", "-p", "x", "--", "--nocapture"]);
    assert_eq!(burst.command, words(&["cargo", "test", "-p", "x", "--", "--nocapture"]));
    assert!(burst.outs.is_empty(), "no --out: nothing comes back by default");
    assert!(burst.start_words.is_empty());
    assert_eq!(burst.timeout, DEFAULT_TIMEOUT);
}

#[test]
fn burst_parse_takes_outs_machine_and_timeout() {
    let burst = run_of(&[
        "--out",
        "target/foo",
        "--out=dist",
        "--name",
        "builder",
        "--environment",
        "env_1",
        "--timeout",
        "90",
        "--",
        "make",
    ]);
    assert_eq!(burst.outs, words(&["target/foo", "dist"]));
    assert_eq!(burst.start_words, words(&["--name", "builder", "--environment", "env_1"]));
    assert_eq!(burst.timeout, Duration::from_secs(90));
    assert_eq!(burst.command, words(&["make"]));
}

#[test]
fn burst_parse_refuses_bad_words() {
    for bad in [
        &["cargo", "test"][..],
        &["--"],
        &["--out", "--", "x"],
        &["--out"],
        &["--timeout", "0", "--", "x"],
        &["--timeout", "soon", "--", "x"],
        &["--name", "a", "--target", "machine:b", "--", "x"],
        &["--prompt", "hi", "--", "x"],
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad:?} parsed");
    }
    assert_eq!(parse(&words(&["--help"])).ok(), Some(Parsed::Help));
    // A `--help` after `--` is the command's own.
    assert_eq!(run_of(&["--", "cargo", "--help"]).command, words(&["cargo", "--help"]));
}

#[test]
fn burst_writeback_plan_keeps_paths_inside_the_folder() {
    let root = Path::new("/work/repo");
    let plan = plan_writeback(
        root,
        &words(&["./target/debug/", "target", "dist/app.js", "target", "dist/app.js.map"]),
    )
    .expect("plan");
    assert_eq!(
        plan,
        vec![
            Writeback { relative: "target".into(), local: PathBuf::from("/work/repo/target") },
            Writeback {
                relative: "dist/app.js".into(),
                local: PathBuf::from("/work/repo/dist/app.js")
            },
            Writeback {
                relative: "dist/app.js.map".into(),
                local: PathBuf::from("/work/repo/dist/app.js.map")
            },
        ],
        "`target/debug` is inside `target`; duplicates go; a sibling with a longer name stays"
    );
    assert_eq!(plan_writeback(root, &[]).expect("none"), vec![]);
    for bad in ["/etc/passwd", "../other", "target/../../x", ".", "./"] {
        assert!(plan_writeback(root, &words(&[bad])).is_err(), "{bad} planned");
    }
}

#[test]
fn burst_exit_status_is_the_commands_own() {
    assert_eq!(exit_status("0\n"), 0);
    assert_eq!(exit_status("3"), 3);
    assert_eq!(exit_status(" 101 "), 101, "cargo test's failure");
    assert_eq!(exit_status("130"), 130, "a shell's 128+SIGINT");
    assert_eq!(exit_status("255"), 255);
    for unknown in ["", "-1", "256", "garbage"] {
        assert_eq!(exit_status(unknown), BURST_FAILED, "{unknown:?}");
    }
}

#[test]
fn burst_command_line_quotes_each_word() {
    assert_eq!(
        command_line(&words(&["cargo", "test", "-p", "cmux-tui"])),
        "cargo test -p cmux-tui"
    );
    assert_eq!(command_line(&words(&["sh", "-c", "a && b"])), "sh -c 'a && b'");
    assert_eq!(command_line(&words(&["echo", "it's"])), "echo 'it'\\''s'");
}

/// A machine that answers each script by its kind, from queues of answers.
#[derive(Default)]
struct FakeMachine {
    polls: VecDeque<String>,
    packs: VecDeque<String>,
    pieces: VecDeque<String>,
    scripts: Vec<String>,
    pauses: u32,
    clock: Option<Instant>,
}

impl Remote for FakeMachine {
    fn exec(&mut self, script: &str) -> Result<String, String> {
        self.scripts.push(script.to_owned());
        let next = |queue: &mut VecDeque<String>| queue.pop_front().ok_or("unexpected".to_owned());
        if script.contains("echo @@started") {
            Ok("@@started\n".into())
        } else if script.contains("echo @@exit") {
            next(&mut self.polls)
        } else if script.contains("tar czf") {
            next(&mut self.packs)
        } else if script.contains("echo @@piece") {
            next(&mut self.pieces)
        } else if script.contains("@@stopped") {
            Ok("@@stopped\n".into())
        } else {
            Err(format!("unknown script {script}"))
        }
    }

    fn pause(&mut self, duration: Duration) {
        self.pauses += 1;
        if let Some(clock) = &mut self.clock {
            *clock += duration;
        }
    }

    fn now(&mut self) -> Instant {
        *self.clock.get_or_insert_with(Instant::now)
    }
}

fn poll(exit: &str, out: &[u8], err: &[u8]) -> String {
    format!("@@exit\n{exit}\n@@out\n{}\n@@err\n{}\n", STANDARD.encode(out), STANDARD.encode(err))
}

#[test]
fn burst_streams_output_and_returns_the_remote_exit_code() {
    let mut machine = FakeMachine::default();
    machine.polls.extend([
        poll("", b"Compiling x\n", b""),
        poll("", b"", b"warning: y\n"),
        poll("101", b"test result: FAILED\n", b""),
    ]);
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let until = machine.now() + Duration::from_secs(60);
    let code = stream(
        &mut machine,
        "job1",
        "/home/cmux/w/repo",
        &words(&["cargo", "test"]),
        until,
        &mut out,
        &mut err,
    )
    .expect("stream");
    assert_eq!(code, 101, "the remote exit code is this process's");
    assert_eq!(String::from_utf8(out).unwrap(), "Compiling x\ntest result: FAILED\n");
    assert_eq!(String::from_utf8(err).unwrap(), "warning: y\n");
    assert_eq!(machine.pauses, 2, "a pause between reads until it ended");
    // Each read asks from where the last left off.
    assert!(machine.scripts[1].contains("tail -c +1 \"$d/out\""), "{}", machine.scripts[1]);
    assert!(machine.scripts[2].contains("tail -c +13 \"$d/out\""), "{}", machine.scripts[2]);
    assert!(machine.scripts[3].contains("tail -c +12 \"$d/err\""), "{}", machine.scripts[3]);
    assert!(machine.scripts[0].contains("cd /home/cmux/w/repo"), "{}", machine.scripts[0]);
}

#[test]
fn burst_reads_everything_before_answering_the_exit_code() {
    let full = vec![b'a'; usize::try_from(READ_PIECE).unwrap()];
    let mut machine = FakeMachine::default();
    machine.polls.extend([poll("0", &full, b""), poll("0", b"tail", b"")]);
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let until = machine.now() + Duration::from_secs(60);
    let code =
        stream(&mut machine, "j", "/w", &words(&["true"]), until, &mut out, &mut err).unwrap();
    assert_eq!(code, 0);
    assert_eq!(out.len(), full.len() + 4, "a full piece means more to read, exit or not");
    assert_eq!(machine.pauses, 0, "no pause while there is more to read");
}

#[test]
fn burst_times_out_and_stops_the_job() {
    let mut machine = FakeMachine::default();
    machine.polls.extend((0..10).map(|_| poll("", b"", b"")));
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let until = machine.now() + POLL_PAUSE * 3;
    let code = stream(&mut machine, "j", "/w", &words(&["sleep", "1d"]), until, &mut out, &mut err)
        .unwrap();
    assert_eq!(code, TIMED_OUT);
    assert!(machine.scripts.last().unwrap().contains("@@stopped"), "the job is stopped");
}

#[test]
fn burst_lost_job_is_an_error_not_an_exit_code() {
    let mut machine = FakeMachine::default();
    machine.polls.push_back("@@lost\n".into());
    let until = machine.now() + Duration::from_secs(60);
    let answer =
        stream(&mut machine, "j", "/w", &words(&["true"]), until, &mut Vec::new(), &mut Vec::new());
    assert!(answer.is_err(), "{answer:?}");
}

#[test]
fn burst_writes_back_each_planned_path_in_pieces() {
    let pack = b"0123456789".to_vec();
    let mut machine = FakeMachine::default();
    machine.packs.extend(["@@missing\n".to_owned(), format!("@@size\n{}\n", pack.len())]);
    machine.pieces.extend([
        format!("@@piece\n{}\n", STANDARD.encode(&pack[..6])),
        format!("@@piece\n{}\n", STANDARD.encode(&pack[6..])),
    ]);
    let plan = plan_writeback(Path::new("/r"), &words(&["nothing", "target/foo"])).unwrap();
    let mut unpacked = Vec::new();
    let mut err = Vec::new();
    let written = write_back(&mut machine, "j", "/w", &plan, &mut err, &mut |bytes| {
        unpacked.push(bytes.to_vec());
        Ok(())
    })
    .unwrap();
    assert_eq!(written, words(&["target/foo"]));
    assert_eq!(unpacked, vec![pack]);
    assert!(String::from_utf8(err).unwrap().contains("--out nothing"), "a missing out is said");
    assert!(
        machine.scripts.iter().any(|script| script.contains("tail -c +7 \"$d/out-1.tgz\"")),
        "the second piece starts after the first: {:?}",
        machine.scripts
    );
}

#[test]
fn burst_writeback_refuses_a_short_pack() {
    let mut machine = FakeMachine::default();
    machine.packs.push_back("@@size\n10\n".into());
    machine.pieces.push_back("@@piece\n\n".into());
    let plan = plan_writeback(Path::new("/r"), &words(&["out"])).unwrap();
    let answer = write_back(&mut machine, "j", "/w", &plan, &mut Vec::new(), &mut |_| Ok(()));
    assert!(answer.is_err(), "{answer:?}");
}

/// The scripts run in a real shell here: the launch detaches, the poll sees the exit status only
/// once the output is whole, and a pack unpacks into another folder.
#[cfg(target_os = "linux")]
#[test]
fn burst_scripts_run_in_a_real_shell() {
    struct Local;
    impl Remote for Local {
        fn exec(&mut self, script: &str) -> Result<String, String> {
            let output = std::process::Command::new("sh")
                .args(["-c", script])
                .output()
                .map_err(|error| error.to_string())?;
            Ok(String::from_utf8_lossy(&output.stdout).into_owned())
        }
        fn pause(&mut self, duration: Duration) {
            std::thread::sleep(duration.min(Duration::from_millis(50)));
        }
        fn now(&mut self) -> Instant {
            Instant::now()
        }
    }
    let work = tempfile::tempdir().unwrap();
    let back = tempfile::tempdir().unwrap();
    let cwd = work.path().display().to_string();
    let job = format!("test-{}", job_id());
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let command = words(&[
        "sh",
        "-c",
        "echo hi; echo oops >&2; mkdir -p target/foo; echo built > target/foo/a.txt; exit 7",
    ]);
    let until = Instant::now() + Duration::from_secs(30);
    let code = stream(&mut Local, &job, &cwd, &command, until, &mut out, &mut err).unwrap();
    assert_eq!(code, 7);
    assert_eq!(String::from_utf8_lossy(&out), "hi\n");
    assert_eq!(String::from_utf8_lossy(&err), "oops\n");
    let plan = plan_writeback(back.path(), &words(&["target/foo", "missing"])).unwrap();
    let root = back.path().to_path_buf();
    let written =
        write_back(&mut Local, &job, &cwd, &plan, &mut Vec::new(), &mut |b| untar(&root, b))
            .unwrap();
    assert_eq!(written, words(&["target/foo"]));
    assert_eq!(std::fs::read_to_string(back.path().join("target/foo/a.txt")).unwrap(), "built\n");
    let _ = std::fs::remove_dir_all(job_dir(&job));
}
