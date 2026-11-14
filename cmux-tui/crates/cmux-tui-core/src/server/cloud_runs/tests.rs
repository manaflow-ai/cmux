use super::*;
use serde_json::json;

#[test]
fn a_runs_child_never_records_the_persons_last_chat() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = std::env::temp_dir().join(format!("cloud-runs-child-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let exe = dir.join("cmux");
    std::fs::write(&exe, "#!/bin/sh\necho \"$CMUX_LAST_CHAT_OFF|$*\"\n").unwrap();
    std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
    let verbs = AppVerbs {
        exe: None,
        socket: PathBuf::from("/tmp/daemon.sock"),
        app_socket: Some(PathBuf::from("/tmp/app.sock")),
        elsewhere: Mutex::default(),
    };
    let output =
        verbs.child(&exe, &["cloud", "start-chat"]).stdout(Stdio::piped()).output().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "1|--json --app-socket /tmp/app.sock cloud start-chat"
    );
}

/// A cancelled or timed-out start ends everything it started, not only the `cmux` it ran:
/// a start's own children (an ssh, a waiting chat) would hold the machine and its pipes
/// (#39022 review at a5563b2d, follow-up).
#[test]
fn a_cancelled_start_ends_the_processes_it_started() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = std::env::temp_dir().join(format!("cloud-runs-group-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let exe = dir.join("cmux");
    let pid_file = dir.join("descendant.pid");
    // The start leaves a child of its own running (off its pipes, so they end with the
    // start), then waits.
    std::fs::write(
        &exe,
        format!(
            "#!/bin/sh\nsleep 30 </dev/null >/dev/null 2>&1 &\necho $! > {}\nwait\n",
            pid_file.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
    let verbs = AppVerbs {
        exe: Some(exe),
        socket: PathBuf::from("/tmp/daemon.sock"),
        app_socket: None,
        elsewhere: Mutex::default(),
    };
    let cancel = AtomicBool::new(false);
    let ran = std::thread::scope(|scope| {
        let call =
            scope.spawn(|| verbs.cmux(&["cloud", "start-chat"], None, STEP_BOUND, Some(&cancel)));
        let began = Instant::now();
        while !pid_file.exists() && began.elapsed() < Duration::from_secs(10) {
            std::thread::sleep(Duration::from_millis(10));
        }
        cancel.store(true, Ordering::Release);
        call.join().unwrap()
    });
    assert_eq!(ran.code, None, "a cancelled start has no exit code");
    let pid: libc::pid_t = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    // SAFETY: signal 0 only asks whether the pid is alive; it sends nothing.
    let alive = || unsafe { libc::kill(pid, 0) } == 0;
    let began = Instant::now();
    while alive() && began.elapsed() < Duration::from_secs(5) {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(!alive(), "the start's own child outlived the cancel");
}

#[test]
fn a_reply_is_the_runs_answer_and_names_its_machine() {
    let got = outcome(Some(0), Ok(json!({ "reply": "hi", "machine_id": "m1" })), false, false);
    assert_eq!(got, Outcome::Replied { reply: "hi".into(), machine: Some("m1".into()) });
}

#[test]
fn the_start_chats_own_timeouts_are_a_timed_out_run() {
    for code in ["cloud.start_pending", "chat.wait_timeout"] {
        let error = json!({ "code": code, "message": "m", "details": { "answer": { "machine_id": "m2" } } });
        assert_eq!(
            outcome(Some(3), Err(error), false, false),
            Outcome::TimedOut { machine: Some("m2".into()) }
        );
    }
    assert_eq!(outcome(None, Err(json!({})), false, true), Outcome::TimedOut { machine: None });
}

#[test]
fn a_failed_turn_keeps_its_reply_and_a_cancel_wins() {
    let error = json!({ "code": "chat.turn_failed", "message": "the turn ended failed",
                            "details": { "reply": "partial", "machine_id": "m3" } });
    assert_eq!(
        outcome(Some(1), Err(error.clone()), false, false),
        Outcome::Failed {
            code: "chat.turn_failed".into(),
            message: "the turn ended failed".into(),
            reply: Some("partial".into()),
            machine: Some("m3".into())
        }
    );
    assert_eq!(
        outcome(None, Err(error), true, false),
        Outcome::Cancelled { machine: Some("m3".into()) }
    );
}

#[test]
fn an_answer_is_read_from_stdout_and_an_error_from_stderr() {
    let ran =
        Ran { code: Some(0), stdout: "noise\n{\"reply\":\"r\"}\n".into(), stderr: String::new() };
    assert_eq!(answer(&ran), Ok(json!({ "reply": "r" })));
    let ran = Ran {
        code: Some(1),
        stdout: String::new(),
        stderr: "{\"code\":\"cloud.signed_out\",\"message\":\"sign in\"}".into(),
    };
    assert_eq!(answer(&ran).unwrap_err()["code"], "cloud.signed_out");
    let ran = Ran { code: None, stdout: String::new(), stderr: "boom".into() };
    assert_eq!(answer(&ran).unwrap_err(), json!({ "code": "step.failed", "message": "boom" }));
}

const NAME: &str = "sandbox-run_1";

/// `cloud list-machines` as `CloudHandlers.machineListFields` answers it: `listedMachine`
/// rows (`machine_id`, `target`, `title`, `status`, `owner`, …), `listedCreation` rows and the
/// account.
/// `user` None: signed out.
fn list(
    loaded: bool,
    user: Option<&str>,
    team: Option<&str>,
    machines: Value,
    creating: Value,
) -> Value {
    let count = machines.as_array().map_or(0, Vec::len);
    json!({
        "loaded": loaded,
        "machines": if loaded { machines } else { json!([]) },
        "count": count,
        "creating": creating,
        "account": { "signed_in": user.is_some(), "user_id": user, "team_id": team },
    })
}

fn listed(id: &str, title: &str, status: &str) -> Value {
    json!({
        "machine_id": id, "target": format!("machine:{id}"), "title": title, "status": status,
        "owner": "team", "created_by": "u1", "created_at": "2026-11-09T00:00:00Z", "error": null,
    })
}

const U1_T1: Option<&str> = Some("user:u1|team:t1");
const U1: Option<&str> = Some("user:u1|personal");

#[test]
fn a_run_machine_is_found_by_its_title_or_its_id_and_deleted() {
    let machines = json!([listed("m-other", "other", "running"), listed("m-9", NAME, "running")]);
    let answer = list(true, Some("u1"), Some("t1"), machines, json!([]));
    assert_eq!(judge(&answer, NAME, None, U1_T1), Judgement::Kill("m-9".into()));
    let renamed =
        list(true, Some("u1"), Some("t1"), json!([listed("m-9", "renamed", "paused")]), json!([]));
    assert_eq!(judge(&renamed, NAME, Some("m-9"), U1_T1), Judgement::Kill("m-9".into()));
}

#[test]
fn only_a_loaded_signed_in_list_of_the_runs_own_person_and_team_says_gone() {
    let empty = json!([]);
    let gone =
        list(true, Some("u1"), Some("t1"), json!([listed("m-x", "x", "running")]), empty.clone());
    assert_eq!(judge(&gone, NAME, Some("m-9"), U1_T1), Judgement::Gone);
    // Not loaded yet (a relaunch, a slow first list): its empty list says nothing.
    let not_loaded = list(false, Some("u1"), Some("t1"), empty.clone(), empty.clone());
    assert!(matches!(judge(&not_loaded, NAME, Some("m-9"), U1_T1), Judgement::Unknown(_)));
    // Signed out: loaded is false and the list is empty.
    let signed_out = list(false, None, None, empty.clone(), empty.clone());
    assert!(matches!(judge(&signed_out, NAME, Some("m-9"), U1_T1), Judgement::Unknown(_)));
    // Signed in to another team (or personal): that list is not the Run's.
    let other = list(true, Some("u1"), Some("t2"), empty.clone(), empty.clone());
    assert!(matches!(judge(&other, NAME, Some("m-9"), U1_T1), Judgement::Unknown(_)));
    let personal = list(true, Some("u1"), None, empty.clone(), empty);
    assert!(matches!(judge(&personal, NAME, None, U1_T1), Judgement::Unknown(_)));
    assert_eq!(judge(&personal, NAME, None, U1), Judgement::Gone);
    // A Run with no scope matches no list.
    assert!(matches!(judge(&personal, NAME, None, None), Judgement::Wait(_)));
}

/// #39022 review at b1bfb468, F1: a list the app read before the Run's create could land
/// (a cached one) never says gone; one read since does, and an app that does not say when
/// it read its list never does.
#[test]
fn only_a_list_read_after_the_create_could_land_says_gone() {
    let mut stale = list(true, Some("u1"), None, json!([]), json!([]));
    stale["listed_at_ms"] = json!(1_000);
    let judged = judge(&stale, NAME, None, U1);
    assert_eq!(judged, Judgement::Gone);
    assert!(matches!(fresh(judged, &stale, 2_000), Judgement::Unknown(_)));
    let mut read = stale.clone();
    read["listed_at_ms"] = json!(2_500);
    assert_eq!(fresh(judge(&read, NAME, None, U1), &read, 2_000), Judgement::Gone);
    let mut unsaid = stale;
    unsaid.as_object_mut().unwrap().remove("listed_at_ms");
    assert!(matches!(fresh(judge(&unsaid, NAME, None, U1), &unsaid, 0), Judgement::Unknown(_)));
    // A machine still listed is deleted whatever the list's age.
    let mut listed =
        list(true, Some("u1"), None, json!([listed("m-9", NAME, "running")]), json!([]));
    listed["listed_at_ms"] = json!(1_000);
    assert_eq!(
        fresh(judge(&listed, NAME, None, U1), &listed, 2_000),
        Judgement::Kill("m-9".into())
    );
}

#[test]
fn another_person_on_the_same_team_or_personal_never_says_gone() {
    // Two personal accounts are two scopes.
    let theirs = list(true, Some("u2"), None, json!([]), json!([]));
    assert!(matches!(judge(&theirs, NAME, Some("m-9"), U1), Judgement::Unknown(_)));
    // The same team under another person is another scope too.
    let teammate = list(true, Some("u2"), Some("t1"), json!([]), json!([]));
    assert!(matches!(judge(&teammate, NAME, None, U1_T1), Judgement::Unknown(_)));
    // A list naming no user (an older app) is no one's.
    let mut nameless = list(true, Some("u1"), None, json!([]), json!([]));
    nameless["account"].as_object_mut().unwrap().remove("user_id");
    assert_eq!(account_scope(&nameless), None);
    assert!(matches!(judge(&nameless, NAME, None, U1), Judgement::Unknown(_)));
    // A scope stored before scopes named the person matches no list.
    let t1 = list(true, Some("u1"), Some("t1"), json!([]), json!([]));
    assert!(matches!(judge(&t1, NAME, None, Some("team:t1")), Judgement::Unknown(_)));
}

/// Codex's review of #39022 at 8c2c83b0 (after 551a7dca's F3): a machine of the Run's own name
/// on another account (a switch during its start) is deleted there, and only a list of an
/// account the start found the app on, showing none of it, clears that account.
#[test]
fn the_runs_machine_on_another_account_is_deleted_there_and_its_list_clears_it() {
    let elsewhere = ["user:u2|personal".to_owned()];
    let theirs = list(true, Some("u2"), None, json!([listed("m-b", NAME, "running")]), json!([]));
    assert_eq!(
        judge_everywhere(&theirs, NAME, None, U1_T1, &elsewhere),
        Judgement::Kill("m-b".into())
    );
    // Another machine's id on that account is never the Run's: only its own name.
    let id_only = list(true, Some("u2"), None, json!([listed("m-9", "dev", "running")]), json!([]));
    assert!(matches!(
        judge_everywhere(&id_only, NAME, Some("m-9"), U1_T1, &elsewhere),
        Judgement::Cleared(_)
    ));
    let empty = list(true, Some("u2"), None, json!([]), json!([]));
    assert_eq!(
        judge_everywhere(&empty, NAME, None, U1_T1, &elsewhere),
        Judgement::Cleared("user:u2|personal".into())
    );
    // An account the start never found the app on clears nothing.
    assert!(matches!(judge_everywhere(&empty, NAME, None, U1_T1, &[]), Judgement::Unknown(_)));
    // A create of the name still on its way there clears nothing.
    let creating = json!([{ "creation_id": "c1", "name": NAME, "status": "creating" }]);
    let on_its_way = list(true, Some("u2"), None, json!([]), creating);
    assert!(matches!(
        judge_everywhere(&on_its_way, NAME, None, U1_T1, &elsewhere),
        Judgement::Creating(_)
    ));
    // #39022 review at 0b52021c, F1: after a switch to an account the start never saw, a
    // create of the Run's name there (a late Start) holds the cleanup too, never the
    // give-up clock.
    assert!(matches!(
        judge_everywhere(&on_its_way, NAME, None, U1_T1, &[]),
        Judgement::Creating(_)
    ));
    let failed = json!([{ "creation_id": "c1", "name": NAME, "status": "failed" }]);
    let failed = list(true, Some("u2"), None, json!([]), failed);
    assert_eq!(
        judge_everywhere(&failed, NAME, None, U1_T1, &elsewhere),
        Judgement::Cleared("user:u2|personal".into())
    );
    // A start-chat refusal names that account.
    let refusal = Err(json!({ "code": "cloud.account_changed", "message": "x",
                                  "details": { "account": "user:u1|team:t1", "app_account": "user:u2|personal",
                                               "machine_id": "vm-1" } }));
    assert_eq!(app_account(&refusal).as_deref(), Some("user:u2|personal"));
    assert!(reached_start(&refusal) && refused_unlisted(&refusal));
    // A refusal before any start answered a machine reached nothing.
    let before = Err(json!({ "code": "cloud.account_changed", "message": "x",
                                 "details": { "account": "user:u1|team:t1", "app_account": "user:u2|personal",
                                              "machine_id": null } }));
    assert!(!reached_start(&before) && !refused_unlisted(&before));
    assert!(reached_start(&Err(json!({ "code": "cloud.start_pending" }))));
    // The account no list names is never cleared.
    let empty = list(true, Some("u2"), None, json!([]), json!([]));
    let unknown = [UNKNOWN_ACCOUNT.to_owned()];
    assert!(matches!(judge_everywhere(&empty, NAME, None, U1_T1, &unknown), Judgement::Unknown(_)));
    assert_eq!(app_account(&Err(json!({ "code": "cloud.start_pending" }))), None);
}

#[test]
fn a_machine_being_deleted_or_still_being_created_is_read_again() {
    let deleting =
        list(true, Some("u1"), None, json!([listed("m-9", NAME, "deleting")]), json!([]));
    assert!(matches!(judge(&deleting, NAME, Some("m-9"), U1), Judgement::Wait(_)));
    let creating = json!([{ "creation_id": "c1", "name": NAME, "status": "creating" }]);
    let on_its_way = list(true, Some("u1"), None, json!([]), creating);
    assert!(matches!(judge(&on_its_way, NAME, None, U1), Judgement::Creating(_)));
    // #39022 audit at 855beb0d (4): a failed create made nothing, and never holds the cleanup.
    let failed =
        json!([{ "creation_id": "c1", "name": NAME, "status": "failed", "reason": "cap" }]);
    let failed = list(true, Some("u1"), None, json!([]), failed);
    assert_eq!(judge(&failed, NAME, None, U1), Judgement::Gone);
}

#[test]
fn the_scope_is_the_lists_person_and_team() {
    assert_eq!(
        account_scope(&list(true, Some("u1"), Some("t1"), json!([]), json!([]))).as_deref(),
        U1_T1
    );
    assert_eq!(account_scope(&list(true, Some("u1"), None, json!([]), json!([]))).as_deref(), U1);
    assert_eq!(account_scope(&list(false, None, None, json!([]), json!([]))), None);
}

fn ran(code: i32, stderr: Value) -> Ran {
    Ran { code: Some(code), stdout: String::new(), stderr: stderr.to_string() }
}

fn pending(sent: Option<&str>) -> Ran {
    let details = match sent {
        Some(sent) => json!({ "machine_id": "m-1", "sent": sent }),
        None => json!({ "machine_name": NAME, "stage": { "status": "provisioning" } }),
    };
    ran(
        75,
        json!({ "code": "cloud.start_pending", "message": "still starting", "details": details }),
    )
}

fn replied() -> Ran {
    let stdout = json!({ "result": { "reply": "done", "machine_id": "m-1" } }).to_string();
    Ran { code: Some(0), stdout, stderr: String::new() }
}

/// Runs `start_until` over `answers` in turn; answers the outcome and the time left each
/// attempt was given.
fn started(timeout: Duration, answers: Vec<Ran>, cancel: &AtomicBool) -> (Outcome, Vec<Duration>) {
    let mut answers = answers.into_iter();
    let mut given = Vec::new();
    let outcome = start_until(timeout, cancel, Duration::from_millis(1), |left| {
        given.push(left);
        answers.next().expect("an answer for every attempt")
    });
    (outcome, given)
}

/// Codex's review of #39022 at 1bf18b3d (F3): a start the app answers pending (its own start
/// window ended) is asked again within the Run's time, never taken as the Run's timeout.
#[test]
fn a_pending_start_is_asked_again_within_the_runs_time() {
    let cancel = AtomicBool::new(false);
    let timeout = Duration::from_secs(600);
    let (got, given) = started(timeout, vec![pending(None), pending(None), replied()], &cancel);
    assert_eq!(got, Outcome::Replied { reply: "done".into(), machine: Some("m-1".into()) });
    assert_eq!(given.len(), 3);
    assert!(given.windows(2).all(|pair| pair[1] <= pair[0]) && given[0] <= timeout, "{given:?}");
}

#[test]
fn a_start_is_not_asked_again_once_the_prompt_may_be_there_or_the_time_is_gone() {
    let cancel = AtomicBool::new(false);
    // The prompt may have reached the machine: asking again could send it twice.
    let (got, given) = started(Duration::from_secs(600), vec![pending(Some("unknown"))], &cancel);
    assert!(matches!(got, Outcome::TimedOut { .. }), "{got:?}");
    assert_eq!(given.len(), 1);
    // A turn that did not end in time is the Run's timeout.
    let wait_timeout = ran(75, json!({ "code": "chat.wait_timeout", "message": "x" }));
    let (got, given) = started(Duration::from_secs(600), vec![wait_timeout], &cancel);
    assert!(matches!(got, Outcome::TimedOut { .. }), "{got:?}");
    assert_eq!(given.len(), 1);
    // No room left for another start.
    let (got, given) = started(Duration::from_millis(1), vec![pending(None)], &cancel);
    assert!(matches!(got, Outcome::TimedOut { .. }), "{got:?}");
    assert_eq!(given.len(), 1);
    // A cancel ends it.
    let cancel = AtomicBool::new(true);
    let (got, given) = started(Duration::from_secs(600), vec![pending(None)], &cancel);
    assert!(matches!(got, Outcome::Cancelled { .. }), "{got:?}");
    assert_eq!(given.len(), 1);
}

#[test]
fn a_child_names_the_app_socket_never_the_daemons() {
    let args = leading_args(Some(Path::new("/tmp/app.sock")));
    assert_eq!(args, ["--json", "--app-socket", "/tmp/app.sock"].map(std::ffi::OsString::from));
    assert_eq!(leading_args(None), [std::ffi::OsString::from("--json")]);
}
