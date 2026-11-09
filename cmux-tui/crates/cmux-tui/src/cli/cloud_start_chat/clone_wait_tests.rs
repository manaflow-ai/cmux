//! A `--cwd` the machine's bootstrap is still cloning (clone_wait.rs, cmuxterm-hq#7415 row 10). A child of
//! `tests`, so its fakes and helpers are in scope.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::*;

/// A start on `vm-1` (an existing machine) in `cwd`, as the start matrix's repo rows run it after
/// `cloud new-machine --repo URL`. It has no prompt, so a start is `start-session` alone.
fn repo_start(cwd: &str, timeout: &str) -> Request {
    request(&["--target", "machine:vm-1", "--cwd", cwd, "--wait", "--timeout", timeout])
}

fn is_folder_check(args: &[String], cwd: &str) -> bool {
    args[..4] == strings(&["cloud", "exec", "--target", "machine:vm-1"])
        && args[5].contains(".cmux/bootstrap")
        && args[5].contains(&shell_quote(cwd))
}

fn refused(code: &str, message: &str) -> Ran {
    Ran { code: 1, stderr: json!({"code": code, "message": message}).to_string(), ..Ran::default() }
}

/// The app's own refusal of `cloud exec` on a machine without API exec (`CloudStrings.execUnavailable`,
/// through `ActionFailure`: code `unavailable`).
const EXEC_UNAVAILABLE: &str = "This Cloud machine can't run a command for the CLI and return its output. \
     Open a terminal on it with `cmux cloud new-terminal-on-machine --target machine:vm-1`, or connect with \
     `cmux cloud ssh --target machine:vm-1`.";

fn is_start(args: &[String]) -> bool {
    args[..2] == strings(&["cloud", "start-session"])
}

fn no_start(ran: &[Vec<String>]) -> bool {
    !ran.iter().any(|args| is_start(args))
}

/// cmuxterm-hq#7415 row 10: `new-machine --repo` answers once the bootstrap started, and the clone
/// runs after it. A start that reached the machine first failed "cwd is not a directory"; it waits
/// for the clone now, for every host and group depth (the folder is always `~/work/NAME`).
#[test]
fn a_start_in_a_folder_still_being_cloned_waits_for_the_clone() {
    for cwd in [
        "/home/cmux/work/Hello-World",
        "/home/cmux/work/gitlab-test",
        "/home/cmux/work/project",
        "/home/cmux/work/tools.v2",
    ] {
        let mut fake =
            Fake::new(vec![signed_in(), exec_out("busy\n"), exec_out("ready\n"), started()]);
        let Outcome::Done(answer) = run(&mut fake, &repo_start(cwd, "900")) else {
            panic!("{cwd}: {:?}", fake.ran)
        };
        assert_eq!(answer["session_id"], "sess-1", "{cwd}");
        assert!(is_folder_check(&fake.ran[1], cwd), "{cwd}: {:?}", fake.ran[1]);
        assert!(is_folder_check(&fake.ran[2], cwd), "{cwd}: {:?}", fake.ran[2]);
        assert!(is_start(&fake.ran[3]), "{cwd}");
        assert_eq!(fake.ran.len(), 4, "{cwd}");
    }
}

/// A ready folder costs one check. A machine that cannot run a command for the CLI (the app's
/// `unavailable` exec refusal, or an app with no `cloud exec`) can't be asked at all: the start goes the
/// way it went before the check.
#[test]
fn a_ready_folder_or_a_machine_that_cannot_exec_starts_as_before() {
    for check in [
        exec_out("ready\n"),
        refused("unavailable", EXEC_UNAVAILABLE),
        refused("action.not_found", "unknown action"),
    ] {
        let mut fake = Fake::new(vec![signed_in(), check.clone(), started()]);
        let Outcome::Done(answer) =
            run(&mut fake, &repo_start("/home/cmux/work/Hello-World", "900"))
        else {
            panic!("{check:?}: {:?}", fake.ran)
        };
        assert_eq!(answer["session_id"], "sess-1");
        assert!(is_start(&fake.ran[2]), "{check:?}");
        assert_eq!(fake.ran.len(), 3);
    }
}

/// Review of #37248 at b925d550: a refusal that may pass later (a busy or starting machine, a timeout,
/// an unreachable app) and an answer that can't be read (empty, garbage, a failed script) are asked
/// again; the chat starts only once the machine says the folder is ready.
#[test]
fn a_check_that_may_pass_later_is_asked_again_and_never_starts_the_chat() {
    for first in [
        refused("vm_busy", "busy"),
        refused("app.unreachable", "no app"),
        refused("cloud.exec_timeout", "the command timed out"),
        exec_out(""),
        exec_out("garbage\n"),
        ok(json!({"exit_code": 2, "stdout": "ready\n", "stderr": "sh: oops"})),
    ] {
        let mut fake = Fake::new(vec![signed_in(), first.clone(), exec_out("ready\n"), started()]);
        let Outcome::Done(_) = run(&mut fake, &repo_start("/home/cmux/work/r", "900")) else {
            panic!("{first:?}: {:?}", fake.ran)
        };
        assert!(is_folder_check(&fake.ran[1], "/home/cmux/work/r"), "{first:?}");
        assert!(is_folder_check(&fake.ran[2], "/home/cmux/work/r"), "{first:?}: {:?}", fake.ran);
        assert!(is_start(&fake.ran[3]), "{first:?}");
        assert_eq!(fake.ran.len(), 4, "{first:?}");
    }
    // Busy until the deadline: out of time, and nothing started.
    let mut fake = Fake::new(vec![signed_in()]);
    fake.answers.extend((0..20).map(|_| refused("vm_busy", "busy")));
    let Outcome::Failed { error, exit } = run(&mut fake, &repo_start("/home/cmux/work/r", "30"))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75));
    assert!(no_start(&fake.ran), "{:?}", fake.ran);
}

/// Any other refusal leaves it unknown whether the folder is ready: a retryable `cloud.folder_unknown`,
/// never a start.
#[test]
fn a_check_refused_any_other_way_is_unknown_and_never_starts_the_chat() {
    for check in [
        refused("vm_forbidden", "not yours"),
        refused("vm_not_found", "gone"),
        refused("step.failed", "boom"),
    ] {
        let mut fake = Fake::new(vec![signed_in(), check.clone()]);
        let Outcome::Failed { error, exit } =
            run(&mut fake, &repo_start("/home/cmux/work/r", "900"))
        else {
            panic!("{check:?}: {:?}", fake.ran)
        };
        assert_eq!(error["code"], "cloud.folder_unknown", "{check:?}");
        assert_eq!(error["retryable"], true);
        assert_eq!(exit, 75);
        assert_eq!(fake.ran.len(), 2, "{check:?}");
    }
}

/// A clone that failed says so, with the bootstrap's status and log, and starts nothing.
#[test]
fn a_bootstrap_that_failed_to_clone_the_folder_says_why() {
    let status = r#"{"state":"failed","exit_code":1,"repo":{"status":"failed","url":"https://gitlab.com/g/sub/r.git"},"step":"repo"}"#;
    let mut fake = Fake::new(vec![signed_in(), exec_out(&format!("ended\n{status}\n"))]);
    let Outcome::Failed { error, exit } = run(&mut fake, &repo_start("/home/cmux/work/r", "900"))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "cloud.folder_missing");
    assert_eq!(exit, 1);
    let message = error["message"].as_str().unwrap();
    assert!(
        message.contains("/home/cmux/work/r") && message.contains("repository failed"),
        "{message}"
    );
    assert!(message.contains("bootstrap.log"), "{message}");
    assert_eq!(error["details"]["bootstrap"]["step"], "repo");
    assert_eq!(fake.ran.len(), 2);
}

/// A clone that outlasts `--timeout` answers out of time, naming the command again, and starts nothing.
#[test]
fn a_clone_longer_than_the_timeout_answers_pending() {
    let mut fake = Fake::new((0..20).map(|_| exec_out("busy\n")).collect::<Vec<_>>());
    fake.answers.push_front(signed_in());
    let Outcome::Failed { error, exit } =
        run(&mut fake, &repo_start("/home/cmux/work/gitlab-test", "30"))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "cloud.start_pending");
    assert_eq!(exit, 75);
    assert!(fake.ran[1..].iter().all(|args| is_folder_check(args, "/home/cmux/work/gitlab-test")));
    assert!(fake.ran.len() <= 8, "bounded by --timeout: {}", fake.ran.len());
}

/// A fake app whose `cloud exec` runs the command in `sh` with `HOME` set to a folder of the test's
/// own, so the folder check's real script reads real bootstrap files. Its `sleep 1` takes no time.
/// Every exec's exit status and stderr are kept (`shell`), and each step moves the clock by `step`.
/// `after` changes the files once the given exec has run.
struct ShellFake {
    home: std::path::PathBuf,
    ran: Vec<Vec<String>>,
    shell: Vec<(Option<i32>, String)>,
    /// `vm-1`'s `created_at` in `list-machines` (default: long ago, so its bootstrap would have started).
    created_at: Value,
    clock: Instant,
    step: Duration,
    execs: usize,
    after: Option<(usize, Box<dyn FnMut(&std::path::Path)>)>,
}

impl ShellFake {
    fn new(home: &std::path::Path) -> Self {
        Self {
            home: home.to_owned(),
            ran: Vec::new(),
            shell: Vec::new(),
            created_at: json!(OLD),
            clock: Instant::now(),
            step: Duration::from_secs(5),
            execs: 0,
            after: None,
        }
    }

    /// Every exec exited 0 and wrote nothing to stderr: a script that broke shows here, not as an answer.
    fn assert_clean(&self) {
        for (code, stderr) in &self.shell {
            assert_eq!((*code, stderr.as_str()), (Some(0), ""), "{:?}", self.ran);
        }
    }
}

impl Runner for ShellFake {
    fn cmux(&mut self, args: &[String]) -> Ran {
        self.ran.push(args.to_vec());
        self.clock += self.step;
        match args.get(1).map(String::as_str) {
            Some("list-machines") => listed(self.created_at.clone()),
            Some("exec") => {
                let command = args[5].replace("sleep 1", ":");
                let out = std::process::Command::new("sh")
                    .arg("-c")
                    .arg(command)
                    .env("HOME", &self.home)
                    .current_dir(&self.home)
                    .output()
                    .unwrap();
                self.execs += 1;
                if let Some((n, change)) = &mut self.after
                    && *n == self.execs
                {
                    change(&self.home);
                }
                let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
                self.shell.push((out.status.code(), stderr.clone()));
                ok(json!({"exit_code": out.status.code().unwrap_or(-1),
                          "stdout": String::from_utf8_lossy(&out.stdout), "stderr": stderr}))
            }
            Some("start-session") => started(),
            other => panic!("no answer for {other:?}"),
        }
    }
    fn pause(&mut self, duration: Duration) {
        self.clock += duration;
    }
    fn now(&mut self) -> Instant {
        self.clock
    }
    fn fresh_name(&mut self) -> String {
        "chat-fresh".into()
    }
}

fn bootstrap(home: &std::path::Path, status: &str, repo: Option<&str>) {
    let dir = home.join(".cmux/bootstrap");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("status.json"), format!("{status}\n")).unwrap();
    match repo {
        Some(repo) => std::fs::write(dir.join("repo-status.json"), format!("{repo}\n")).unwrap(),
        None => {
            let _ = std::fs::remove_file(dir.join("repo-status.json"));
        }
    }
}

const RUNNING: &str =
    r#"{"state":"running","exit_code":null,"script_sha256":"a","start_sha256":"b","at":1}"#;
const DONE: &str =
    r#"{"state":"done","exit_code":0,"script_sha256":"a","start_sha256":"b","repo":null,"at":1}"#;
const FAILED_SCRIPT: &str = r#"{"state":"failed","exit_code":2,"script_sha256":"a","start_sha256":"b","repo":null,"at":1,"step":"script"}"#;
const FAILED_REPO: &str = r#"{"state":"failed","exit_code":1,"script_sha256":"a","start_sha256":"b","repo":{"status":"failed"},"at":1,"step":"repo"}"#;
const CLONED: &str = r#"{"status":"cloned","url":"https://gitlab.com/g/r.git","ref":"","dir":"x","credential":"none","sha":"c"}"#;
const KEPT: &str = r#"{"status":"kept","url":"https://gitlab.com/g/r.git","ref":"","dir":"x","credential":"none","sha":"c"}"#;

/// Review of #37248: `git clone URL DIR` makes DIR before its checkout ends, so a folder that is there
/// while the bootstrap runs is not ready. The start waits for the repository step's own status.
#[test]
fn a_folder_that_is_there_while_the_clone_runs_is_not_ready_until_the_repo_step_says_so() {
    let home = tempfile::tempdir().unwrap();
    let cwd = home.path().join("work/gitlab-test");
    std::fs::create_dir_all(cwd.join(".git")).unwrap();
    bootstrap(home.path(), RUNNING, None);
    let mut fake = ShellFake::new(home.path());
    fake.after = Some((2, Box::new(|home| bootstrap(home, RUNNING, Some(CLONED)))));
    let cwd = cwd.to_str().unwrap();
    let Outcome::Done(answer) = run(&mut fake, &repo_start(cwd, "900")) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["session_id"], "sess-1");
    // Two checks said busy (the folder was there), the third read the repository step's `cloned`.
    assert_eq!(fake.ran.len(), 5, "{:?}", fake.ran);
    assert!(fake.ran[1..4].iter().all(|args| is_folder_check(args, cwd)), "{:?}", fake.ran);
    assert!(is_start(&fake.ran[4]));
    fake.assert_clean();
}

/// The bootstrap files decide. No bootstrap: the folder being there is enough. The repository step
/// cloned (or the whole bootstrap done) starts; a failed `status.json` wins over a `kept` repository
/// and fails the start, as does any failed bootstrap.
#[test]
fn the_bootstrap_files_decide_whether_the_folder_is_ready() {
    for (status, repo, folder, starts) in [
        (None, None, true, true),
        (Some(DONE), Some(CLONED), true, true),
        (Some(RUNNING), Some(CLONED), true, true),
        (Some(FAILED_SCRIPT), Some(KEPT), true, false),
        (Some(FAILED_SCRIPT), None, true, false),
        (Some(FAILED_REPO), Some(r#"{"status":"failed"}"#), false, false),
    ] {
        let home = tempfile::tempdir().unwrap();
        let cwd = home.path().join("work/r");
        if folder {
            std::fs::create_dir_all(&cwd).unwrap();
        }
        if let Some(status) = status {
            bootstrap(home.path(), status, repo);
        }
        let mut fake = ShellFake::new(home.path());
        let got = run(&mut fake, &repo_start(cwd.to_str().unwrap(), "900"));
        match (starts, got) {
            (true, Outcome::Done(answer)) => assert_eq!(answer["session_id"], "sess-1"),
            (false, Outcome::Failed { error, .. }) => {
                assert_eq!(error["code"], "cloud.folder_missing", "{status:?} {repo:?}");
                assert_eq!(fake.ran.len(), 2);
            }
            (_, other) => {
                panic!("{status:?} {repo:?} folder {folder}: {other:?} {:?}", fake.ran)
            }
        }
        fake.assert_clean();
    }
}

/// No bootstrap and no folder on a machine old enough that its bootstrap would have started (a typo in
/// `--cwd`): a typed `cloud.folder_missing` (`no_such_folder`, exit 1, no bootstrap log) at the first
/// check, never a start and never a wait to the deadline.
#[test]
fn no_bootstrap_and_no_folder_on_an_old_machine_is_no_such_folder() {
    for timeout in ["900", "20"] {
        let home = tempfile::tempdir().unwrap();
        let mut fake = ShellFake::new(home.path());
        let cwd = home.path().join("work/typo");
        let began = fake.clock;
        let Outcome::Failed { error, exit } =
            run(&mut fake, &repo_start(cwd.to_str().unwrap(), timeout))
        else {
            panic!("{:?}", fake.ran)
        };
        assert_eq!((error["code"].as_str(), exit), (Some("cloud.folder_missing"), 1), "{error}");
        assert_eq!(error["details"]["reason"], "no_such_folder");
        assert!(
            error["details"].get("log").is_none() && error["details"].get("bootstrap").is_none()
        );
        assert!(!error["message"].as_str().unwrap().contains("bootstrap.log"), "{error}");
        let spent = fake.clock.saturating_duration_since(began);
        assert!(spent <= Duration::from_secs(45), "{timeout}: {spent:?}");
        assert_eq!(fake.ran.len(), 2, "missing at the first check: {:?}", fake.ran);
        assert!(no_start(&fake.ran), "{:?}", fake.ran);
        fake.assert_clean();
    }
}

/// A bootstrap that shows up inside the grace is waited on like any other.
#[test]
fn a_bootstrap_that_shows_up_inside_the_grace_is_waited_on() {
    let mut fake = Fake::new(vec![
        signed_in(),
        exec_out("absent\n"),
        exec_out("busy\n"),
        exec_out("ready\n"),
        started(),
    ]);
    let Outcome::Done(_) = run(&mut fake, &repo_start("/home/cmux/work/r", "900")) else {
        panic!("{:?}", fake.ran)
    };
    assert!(is_start(&fake.ran[4]), "{:?}", fake.ran);
}

/// Review of #37248: one deadline from the command's start. Each check waits on the machine at most
/// what is left of it.
#[test]
fn the_folder_wait_and_the_start_share_one_deadline_from_the_command_start() {
    let mut fake = Fake::new((0..10).map(|_| exec_out("busy\n")).collect::<Vec<_>>());
    fake.answers.push_front(signed_in());
    let Outcome::Failed { error, .. } = run(&mut fake, &repo_start("/home/cmux/work/r", "22"))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "cloud.start_pending");
    // The list took 5 s of the 22: checks of 15 s (the most), then 12, 7 and 2.
    for (step, slice) in [(1, 15), (2, 12), (3, 7), (4, 2)] {
        assert!(
            fake.ran[step][5].contains(&format!("-lt {slice} ]")),
            "{step}: {:?}",
            fake.ran[step]
        );
    }
    assert_eq!(fake.ran.len(), 5, "no check starts past the deadline: {:?}", fake.ran);
}

/// Review of #37248 at b925d550: under a second left is out of time, with no check at all (never a
/// one-second check past the deadline).
#[test]
fn under_a_second_left_is_out_of_time_without_a_check() {
    let home = tempfile::tempdir().unwrap();
    bootstrap(home.path(), RUNNING, None);
    let mut fake = ShellFake::new(home.path());
    fake.step = Duration::from_millis(4600);
    let cwd = home.path().join("work/r");
    let Outcome::Failed { error, exit } = run(&mut fake, &repo_start(cwd.to_str().unwrap(), "5"))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75));
    assert_eq!(fake.ran.len(), 1, "only the list ran: {:?}", fake.ran);
}

/// `--cwd` is one shell word on the machine whatever it holds: quotes, `$(...)`, backquotes and a
/// newline name the folder and run nothing, the script exits 0 with nothing on stderr, and the answer
/// names exactly that folder.
#[test]
fn a_cwd_with_shell_text_in_it_is_only_ever_a_folder_name() {
    for name in [
        "it's",
        "$(touch pwned)",
        "`touch pwned`",
        "a\"b\" ; touch pwned ; \"",
        "two\nlines",
        "$HOME",
        "x'\"$(id)\"'y",
    ] {
        let home = tempfile::tempdir().unwrap();
        let cwd = home.path().join("work").join(name);
        let cwd = cwd.to_str().unwrap();
        let pwned =
            || home.path().join("pwned").exists() || home.path().join("work/pwned").exists();
        // No bootstrap: the folder alone decides, so the script must test exactly this name.
        std::fs::create_dir_all(cwd).unwrap();
        let mut fake = ShellFake::new(home.path());
        let Outcome::Done(_) = run(&mut fake, &repo_start(cwd, "900")) else {
            panic!("{name:?}: {:?}", fake.ran)
        };
        assert!(is_folder_check(&fake.ran[1], cwd), "{name:?}");
        assert_eq!(fake.ran[2][fake.ran[2].iter().position(|w| w == "--cwd").unwrap() + 1], cwd);
        fake.assert_clean();
        assert!(!pwned(), "{name:?} ran");
        // A missing folder of that name is not ready (a sibling of another name does not count).
        std::fs::remove_dir(cwd).unwrap();
        std::fs::create_dir_all(home.path().join("work/other")).unwrap();
        let mut fake = ShellFake::new(home.path());
        let Outcome::Failed { error, .. } = run(&mut fake, &repo_start(cwd, "20")) else {
            panic!("{name:?}: {:?}", fake.ran)
        };
        assert_eq!(error["details"]["reason"], "no_such_folder", "{name:?}");
        assert_eq!(error["details"]["cwd"], cwd, "{name:?}");
        assert!(no_start(&fake.ran), "{name:?}");
        fake.assert_clean();
        assert!(!pwned(), "{name:?} ran");
    }
}

/// Review of #37248 at 948eeb00: `cloud exec` doesn't wake a paused machine (start-session does). A check
/// refused `vm_not_running` resumes the machine once (`cloud resume-machine`, as start-session's resume),
/// then checks again: a paused machine with its folder ready starts, and one still cloning is waited on.
#[test]
fn a_paused_machine_is_resumed_once_then_checked() {
    let resume = strings(&["cloud", "resume-machine", "--target", "machine:vm-1", "--json"]);
    let mut fake = Fake::new(vec![
        signed_in(),
        refused("vm_not_running", "the machine is paused"),
        ok(json!({})),
        refused("vm_not_running", "the machine is still starting"),
        exec_out("busy\n"),
        exec_out("ready\n"),
        started(),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &repo_start("/home/cmux/work/r", "900")) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["session_id"], "sess-1");
    assert_eq!(fake.ran[2], resume, "{:?}", fake.ran);
    assert_eq!(fake.ran.iter().filter(|args| **args == resume).count(), 1, "{:?}", fake.ran);
    for step in [1, 3, 4, 5] {
        assert!(is_folder_check(&fake.ran[step], "/home/cmux/work/r"), "{step}: {:?}", fake.ran);
    }
    assert!(is_start(&fake.ran[6]));
    assert_eq!(fake.ran.len(), 7);

    // A resume the app refuses for good leaves it unknown: no start.
    let mut fake = Fake::new(vec![
        signed_in(),
        refused("vm_not_running", "the machine is paused"),
        refused("vm_forbidden", "not yours"),
    ]);
    let Outcome::Failed { error, .. } = run(&mut fake, &repo_start("/home/cmux/work/r", "900"))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "cloud.folder_unknown");
    assert!(no_start(&fake.ran), "{:?}", fake.ran);
}

/// Review of #37248 at 948eeb00: the check's answer is exactly one of its lines (trailing whitespace at
/// most); anything more is malformed, asked again, and never ready.
#[test]
fn an_answer_with_more_than_its_line_is_malformed_and_asked_again() {
    for extra in [
        "ready\nanything\n",
        "ready\n\nready\n",
        "busy\nready\n",
        "absent\nx\n",
        "x\nready\n",
        "ended\n{\"state\":\"failed\"}\nmore\n",
        "ended\nnot json\n",
    ] {
        let mut fake =
            Fake::new(vec![signed_in(), exec_out(extra), exec_out("ready  \n"), started()]);
        let Outcome::Done(_) = run(&mut fake, &repo_start("/home/cmux/work/r", "900")) else {
            panic!("{extra:?}: {:?}", fake.ran)
        };
        assert!(is_folder_check(&fake.ran[2], "/home/cmux/work/r"), "{extra:?}: {:?}", fake.ran);
        assert!(is_start(&fake.ran[3]), "{extra:?}");
        assert_eq!(fake.ran.len(), 4, "{extra:?}");
    }
}

/// `list-machines` with `vm-1` created at `created_at`.
fn listed(created_at: Value) -> Ran {
    ok(json!({"account": {"signed_in": true},
              "machines": [{"machine_id": "vm-1", "title": "m", "created_at": created_at}]}))
}

const OLD: &str = "2020-01-01T00:00:00Z";

/// `at` as the app writes `created_at` (`Date.formatted(.iso8601)`: `2026-11-07T01:23:45Z`).
fn iso(at: std::time::SystemTime) -> String {
    let secs = at.duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
    let (days, rest) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

/// Review of #37248 at 4672e358: a young machine (its bootstrap may not have written its status yet:
/// the app writes five files of up to 120 s each first) is waited on past any fixed grace, and starts
/// once its bootstrap shows up and clones the folder.
#[test]
fn a_young_machine_whose_bootstrap_shows_up_late_is_waited_on() {
    let home = tempfile::tempdir().unwrap();
    let cwd = home.path().join("work/r");
    let mut fake = ShellFake::new(home.path());
    fake.created_at = json!(iso(std::time::SystemTime::now()));
    let made = cwd.clone();
    // About 90 s of checks with nothing there, then the bootstrap's status and its clone.
    fake.after = Some((
        13,
        Box::new(move |home| {
            std::fs::create_dir_all(&made).unwrap();
            bootstrap(home, RUNNING, Some(CLONED));
        }),
    ));
    let began = fake.clock;
    let Outcome::Done(answer) = run(&mut fake, &repo_start(cwd.to_str().unwrap(), "900")) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["session_id"], "sess-1");
    assert!(
        fake.clock.saturating_duration_since(began) > Duration::from_secs(60),
        "{:?}",
        fake.ran
    );
    assert!(is_start(fake.ran.last().unwrap()));
    fake.assert_clean();
}

/// A machine whose age can't be read (no `created_at`, an unreadable one, not listed) counts as young:
/// no bootstrap and no folder waits to the deadline and never reads as missing or starts.
#[test]
fn a_machine_of_unknown_age_is_waited_on_to_the_deadline() {
    for created_at in [Value::Null, json!("yesterday"), json!(12)] {
        let home = tempfile::tempdir().unwrap();
        let mut fake = ShellFake::new(home.path());
        fake.created_at = created_at.clone();
        let cwd = home.path().join("work/r");
        let Outcome::Failed { error, exit } =
            run(&mut fake, &repo_start(cwd.to_str().unwrap(), "60"))
        else {
            panic!("{created_at}: {:?}", fake.ran)
        };
        assert_eq!(
            (error["code"].as_str(), exit),
            (Some("cloud.start_pending"), 75),
            "{created_at}"
        );
        assert!(no_start(&fake.ran), "{created_at}");
        fake.assert_clean();
    }
}

/// Review of #37248 at 4672e358: with `--timeout`, the deadline is the only bound (the 10 minute cap is
/// for a start with no deadline).
#[test]
fn a_timeout_over_ten_minutes_is_the_only_bound() {
    let mut fake = Fake::new(vec![signed_in()]);
    fake.answers.extend((0..400).map(|_| exec_out("busy\n")));
    let began = fake.clock;
    let Outcome::Failed { error, .. } = run(&mut fake, &repo_start("/home/cmux/work/r", "1200"))
    else {
        panic!("{:?}", fake.ran.len())
    };
    assert_eq!(error["code"], "cloud.start_pending", "{error}");
    assert!(fake.clock.saturating_duration_since(began) >= Duration::from_secs(1200));
}

/// Review of #37248 at 4672e358: an answer that comes back past the deadline is out of time, never a
/// start; a resume is never asked for past it.
#[test]
fn an_answer_past_the_deadline_is_out_of_time() {
    // The list takes 5 s of the 9, the check the rest and more: its `ready` is late.
    for (answer, never) in [
        (exec_out("ready\n"), "start-session"),
        (refused("vm_not_running", "paused"), "resume-machine"),
    ] {
        let mut fake = Fake::new(vec![signed_in(), answer.clone(), ok(json!({})), started()]);
        let Outcome::Failed { error, exit } = run(&mut fake, &repo_start("/home/cmux/work/r", "9"))
        else {
            panic!("{answer:?}: {:?}", fake.ran)
        };
        assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75), "{answer:?}");
        assert!(no_start(&fake.ran), "{answer:?}: {:?}", fake.ran);
        assert!(fake.ran.iter().all(|args| args[1] != never), "{answer:?}: {:?}", fake.ran);
        assert_eq!(fake.ran.len(), 2, "{answer:?}: {:?}", fake.ran);
    }
}

/// Review of #37248 at bcbe5d7f: the Cloud API's `vm_state_conflict` (a retryable 409 while a machine
/// starts, pauses or isn't running) may pass later. The first one resumes the machine like
/// `vm_not_running` does; one right after a resume is the machine coming up, and is asked again.
#[test]
fn a_state_conflict_is_asked_again_and_resumes_once() {
    let resume = strings(&["cloud", "resume-machine", "--target", "machine:vm-1", "--json"]);
    for first in [
        refused("vm_state_conflict", "the machine is pausing"),
        refused("vm_not_running", "paused"),
    ] {
        let mut fake = Fake::new(vec![
            signed_in(),
            first.clone(),
            ok(json!({})),
            refused("vm_state_conflict", "the machine is starting"),
            exec_out("busy\n"),
            exec_out("ready\n"),
            started(),
        ]);
        let Outcome::Done(answer) = run(&mut fake, &repo_start("/home/cmux/work/r", "900")) else {
            panic!("{first:?}: {:?}", fake.ran)
        };
        assert_eq!(answer["session_id"], "sess-1");
        assert_eq!(fake.ran[2], resume, "{first:?}: {:?}", fake.ran);
        assert_eq!(fake.ran.iter().filter(|args| **args == resume).count(), 1, "{first:?}");
        assert!(is_start(&fake.ran[6]), "{first:?}");
        assert_eq!(fake.ran.len(), 7, "{first:?}");
    }
    // Conflicts until the deadline: out of time, nothing started.
    let mut fake = Fake::new(vec![signed_in()]);
    fake.answers.extend((0..20).map(|_| refused("vm_state_conflict", "starting")));
    let Outcome::Failed { error, .. } = run(&mut fake, &repo_start("/home/cmux/work/r", "30"))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "cloud.start_pending");
    assert!(no_start(&fake.ran), "{:?}", fake.ran);
}

/// `list-machines` with a create of `box` still on its way, or with `box` made as `vm-1` (just now).
fn creating_box() -> Ran {
    ok(json!({"account": {"signed_in": true}, "machines": [],
              "creating": [{"name": "box", "status": "creating"}]}))
}

fn made_box() -> Ran {
    ok(json!({"account": {"signed_in": true}, "creating": [],
              "machines": [{"machine_id": "vm-1", "title": "box",
                            "created_at": iso(std::time::SystemTime::now())}]}))
}

/// Review of #37248 at bcbe5d7f: a `--name` whose create is still on its way (`list-machines`'
/// `creating`) is waited on until the machine is listed, then its folder like any young machine's; the
/// chat never starts before the folder is ready.
#[test]
fn a_named_machine_still_being_made_is_waited_on_before_its_folder_check() {
    let asked =
        request(&["--name", "box", "--cwd", "/home/cmux/work/r", "--wait", "--timeout", "900"]);
    let mut fake = Fake::new(vec![
        creating_box(),
        creating_box(),
        made_box(),
        exec_out("busy\n"),
        exec_out("ready\n"),
        started(),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["session_id"], "sess-1");
    let list = strings(&["cloud", "list-machines", "--json"]);
    assert_eq!(fake.ran[..3], [list.clone(), list.clone(), list], "{:?}", fake.ran);
    assert!(
        is_folder_check(&fake.ran[3], "/home/cmux/work/r")
            && is_folder_check(&fake.ran[4], "/home/cmux/work/r")
    );
    assert!(is_start(&fake.ran[5]), "{:?}", fake.ran);
    assert_eq!(fake.ran.len(), 6);

    // Still being made at the deadline: out of time, nothing started.
    let asked = request(&[
        "--prompt",
        "ok?",
        "--name",
        "box",
        "--cwd",
        "/home/cmux/work/r",
        "--wait",
        "--timeout",
        "30",
    ]);
    let mut fake = Fake::new((0..20).map(|_| creating_box()).collect::<Vec<_>>());
    let Outcome::Failed { error, .. } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(error["code"], "cloud.start_pending");
    assert!(no_start(&fake.ran), "{:?}", fake.ran);
}

fn named_start(timeout: &str) -> Request {
    request(&[
        "--prompt",
        "ok?",
        "--name",
        "box",
        "--cwd",
        "/home/cmux/work/r",
        "--wait",
        "--timeout",
        timeout,
    ])
}

/// Review of #37248 at 7289f988: a create that the wait sees fail is judged on that newest list, so the
/// answer is the create's failure (`cloud.start_failed`, with its reason), never "still being made".
#[test]
fn a_named_create_that_fails_during_the_wait_is_its_failure_not_pending() {
    let failed_box = ok(json!({"account": {"signed_in": true}, "machines": [],
                               "creating": [{"name": "box", "status": "failed", "reason": "quota"}]}));
    let mut fake = Fake::new(vec![creating_box(), failed_box]);
    let Outcome::Failed { error, exit } = run(&mut fake, &named_start("900")) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_failed"), 1), "{error}");
    assert!(error["message"].as_str().unwrap().contains("quota"), "{error}");
    let list = strings(&["cloud", "list-machines", "--json"]);
    assert_eq!(fake.ran, [list.clone(), list], "{:?}", fake.ran);
}

/// Review of #37248 at 7289f988: a create that is gone from the newest list (dismissed) is nothing to
/// wait for and nothing pending: the start goes on, and `start-session --name` makes the machine.
#[test]
fn a_named_create_gone_from_the_newest_list_goes_on_to_the_start() {
    let gone = ok(json!({"account": {"signed_in": true}, "machines": [], "creating": []}));
    let mut fake = Fake::new(vec![creating_box(), gone, refused("boom", "no machine for you")]);
    let Outcome::Failed { error, .. } = run(&mut fake, &named_start("900")) else {
        panic!("{:?}", fake.ran)
    };
    assert_ne!(error["code"], "cloud.start_pending", "{error}");
    let list = strings(&["cloud", "list-machines", "--json"]);
    assert_eq!(fake.ran[..2], [list.clone(), list], "{:?}", fake.ran);
    assert_eq!(fake.ran[2][..4], strings(&["cloud", "start-session", "--name", "box"]));
    assert_eq!(fake.ran.len(), 3, "{:?}", fake.ran);
}

/// Review of #37248 at 7289f988: the one deadline (#37159) holds through the wait for a create. A pause
/// that reaches it starts no further list: out of time, with nothing more asked of the app.
#[test]
fn a_pause_that_reaches_the_deadline_starts_no_further_list() {
    // The list ends at 5 s, with 1 s left; the pause takes that second.
    let mut fake = Fake::new((0..5).map(|_| creating_box()).collect::<Vec<_>>());
    let Outcome::Failed { error, exit } = run(&mut fake, &named_start("6")) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75), "{error}");
    assert_eq!(fake.paused, Duration::from_secs(1));
    assert_eq!(fake.ran.len(), 1, "no call after the pause reached the deadline: {:?}", fake.ran);
}

/// The same for the folder check's own pause: one that reaches the deadline starts no further check.
#[test]
fn a_folder_check_pause_that_reaches_the_deadline_starts_no_further_check() {
    // The list ends at 5 s and the check at 10 s, with 2 s left; the pause takes them.
    let mut fake = Fake::new(vec![signed_in(), exec_out("unknown\n"), exec_out("ready\n")]);
    let Outcome::Failed { error, exit } = run(&mut fake, &repo_start("/home/cmux/work/r", "12"))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75), "{error}");
    assert_eq!(fake.paused, Duration::from_secs(2));
    assert_eq!(fake.ran.len(), 2, "no call after the pause reached the deadline: {:?}", fake.ran);
}

/// The merge of #37159 into #37248: `run` answers a step that ran past the deadline as that phase's timeout
/// (`Progress::late`). A folder wait on a `--name`d machine that runs out still names the machine it waited
/// on, by its id, as the folder wait itself does.
#[test]
fn a_named_machines_folder_wait_past_the_deadline_names_that_machine() {
    let asked = request(&[
        "--prompt",
        "ok?",
        "--name",
        "box",
        "--cwd",
        "/home/cmux/work/r",
        "--wait",
        "--timeout",
        "30",
    ]);
    let mut fake = Fake::new(vec![made_box()]);
    fake.answers.extend((0..20).map(|_| exec_out("busy\n")));
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75), "{error}");
    assert_eq!(error["details"]["machine_id"], "vm-1", "{error}");
    assert!(no_start(&fake.ran), "{:?}", fake.ran);
}

/// Review of #37248 at bcbe5d7f: with no deadline (no `--wait`), the 10 minute cap is checked when each
/// call returns too: a `ready` (or a `vm_not_running`) that comes back at the cap is late, never a start
/// or a resume.
#[test]
fn an_answer_at_the_ten_minute_cap_is_late() {
    for last in [exec_out("ready\n"), refused("vm_not_running", "paused")] {
        let mut fake = Fake::new(vec![signed_in()]);
        // The list ends at 5 s; the 119th check starts at 595 s and comes back at 600 s.
        fake.answers.extend((0..118).map(|_| exec_out("busy\n")));
        fake.answers.push_back(last.clone());
        let asked =
            request(&["--prompt", "ok?", "--target", "machine:vm-1", "--cwd", "/home/cmux/work/r"]);
        let Outcome::Failed { error, exit } = run(&mut fake, &asked) else {
            panic!("{last:?}: {:?}", &fake.ran[fake.ran.len().saturating_sub(3)..])
        };
        assert_eq!((error["code"].as_str(), exit), (Some("cloud.folder_pending"), 75), "{last:?}");
        assert!(no_start(&fake.ran), "{last:?}");
        assert!(fake.ran.iter().all(|args| args[1] != "resume-machine"), "{last:?}");
        assert_eq!(fake.ran.len(), 120, "{last:?}");
    }
}

/// Review of #37248 at bcbe5d7f: `--environment` makes a new machine, so `--environment --name EXISTING`
/// is a usage error before any folder check.
#[test]
fn environment_with_an_existing_name_is_refused_before_any_folder_check() {
    let listing = ok(json!({"account": {"signed_in": true}, "creating": [],
                            "machines": [{"machine_id": "vm-1", "title": "box", "created_at": OLD}]}));
    let asked = request(&[
        "--prompt",
        "ok?",
        "--environment",
        "env_1",
        "--name",
        "box",
        "--cwd",
        "/home/cmux/work/r",
        "--wait",
    ]);
    let mut fake = Fake::new(vec![listing]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!((error["code"].as_str(), exit), (Some("usage.invalid"), 2), "{error}");
    assert_eq!(fake.ran.len(), 1, "{:?}", fake.ran);
}
