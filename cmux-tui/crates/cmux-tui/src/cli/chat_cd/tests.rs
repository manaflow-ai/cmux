use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde_json::json;

use super::*;
use crate::cli::cloud_start_chat::Ran;

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn cd(words: &[&str]) -> Cd {
    match parse(&strings(words)) {
        Ok(Parsed::Run(cd)) => cd,
        other => panic!("{words:?}: {other:?}"),
    }
}

fn refused(words: &[&str]) -> String {
    match parse(&strings(words)) {
        Err(error) => error.0,
        other => panic!("{words:?} parsed: {other:?}"),
    }
}

/// A fake app: each `cloud exec` answers from a queue; the scripts it got are kept.
struct Fake {
    answers: VecDeque<Ran>,
    scripts: Vec<String>,
    clock: Instant,
    paused: Duration,
}

impl Fake {
    fn new(answers: Vec<Ran>) -> Self {
        Self {
            answers: answers.into(),
            scripts: Vec::new(),
            clock: Instant::now(),
            paused: Duration::ZERO,
        }
    }
}

impl Runner for Fake {
    fn cmux(&mut self, args: &[String]) -> Ran {
        assert_eq!(
            args.get(..4),
            Some(&strings(&["cloud", "exec", "--target", "machine:vm-1"])[..])
        );
        self.scripts.push(args.get(5).cloned().unwrap_or_default());
        self.clock += Duration::from_secs(2);
        self.answers.pop_front().expect("an answer for every exec")
    }
    fn pause(&mut self, duration: Duration) {
        self.paused += duration;
        self.clock += duration;
    }
    fn now(&mut self) -> Instant {
        self.clock
    }
    fn fresh_name(&mut self) -> String {
        "unused".into()
    }
}

fn out(stdout: &str) -> Ran {
    Ran {
        code: 0,
        stdout: json!({"result": {"exit_code": 0, "stdout": stdout, "stderr": ""}}).to_string(),
        ..Ran::default()
    }
}

fn forked(id: &str) -> Ran {
    out(&format!("@@fork\n{}\n@@exit 0", json!({"sessionId": id, "_meta": {"acpmux": {}}})))
}

#[test]
fn a_folder_or_a_repository_and_the_chat_it_moves() {
    assert_eq!(
        cd(&["s-1", "~/work/api"]),
        Cd {
            session: "s-1".into(),
            folder: Folder::Dir("~/work/api".into()),
            on: None,
            timeout: DEFAULT_TIMEOUT,
        }
    );
    let repo =
        cd(&["s-1", "--repo", "acme/api", "--ref=main", "--on", "vm:dev", "--timeout", "90"]);
    assert_eq!(
        repo.folder,
        Folder::Repo { repo: "acme/api".into(), reference: Some("main".into()) }
    );
    assert_eq!(repo.on.as_deref(), Some("vm:dev"));
    assert_eq!(repo.timeout, Duration::from_secs(90));
    assert_eq!(parse(&strings(&["--help"])), Ok(Parsed::Help));
}

#[test]
fn a_cd_names_one_chat_and_one_folder_on_the_machine() {
    assert!(refused(&[]).contains("SESSION"));
    assert!(refused(&["s-1"]).contains("DIR, or --repo"));
    assert!(refused(&["s-1", "work/api"]).contains("absolute or ~/PATH"));
    assert!(refused(&["s-1", "/w", "--repo", "a/b"]).contains("not both"));
    assert!(refused(&["s-1", "/w", "--ref", "main"]).contains("--ref goes with --repo"));
    assert!(refused(&["s-1", "--repo", "--ref"]).contains("--repo"));
    assert!(refused(&["a/b", "/w"]).contains("no session id"));
    assert!(refused(&["s-1", "/w", "/x"]).contains("unexpected argument"));
    assert!(refused(&["s-1", "/w", "--timeout", "0"]).contains("seconds"));
}

#[test]
fn a_folder_cd_checks_the_folder_then_forks_the_chat_into_it() {
    let mut fake = Fake::new(vec![out("@@folder\n/home/cmux/work/api\n"), forked("s-2")]);
    let answer = run(&mut fake, &cd(&["s-1", "~/work/api"]), "vm-1").expect("moved");
    assert_eq!(answer["session_id"], "s-2");
    assert_eq!(answer["forked_from"], "s-1");
    assert_eq!(answer["cwd"], "/home/cmux/work/api");
    assert_eq!(answer["target"], "machine:vm-1");
    assert_eq!(answer["follow_up"]["send"], "cmux chat send s-2 'PROMPT' --wait");
    assert_eq!(
        answer["follow_up"]["new_chat"],
        "cmux cloud start-chat --target machine:vm-1 --cwd /home/cmux/work/api --prompt 'PROMPT'"
    );
    assert!(fake.scripts[0].contains("d='~/work/api'"), "{}", fake.scripts[0]);
    assert!(
        fake.scripts[1].contains("acp session fork s-1 --cwd /home/cmux/work/api --json"),
        "{}",
        fake.scripts[1]
    );
}

#[test]
fn a_folder_the_machine_lacks_is_refused_before_any_fork() {
    let mut fake = Fake::new(vec![out("@@missing\n")]);
    let error = run(&mut fake, &cd(&["s-1", "/nope"]), "vm-1").expect_err("no folder");
    assert_eq!(error["code"], "chat_cd.not_a_folder");
    assert_eq!(fake.scripts.len(), 1);
}

#[test]
fn a_repo_cd_clones_through_add_repository_in_the_background_and_asks_until_it_ends() {
    let attached = json!({"repo": "acme/api", "folder": "/home/cmux/chats/s-1/api",
                          "state": "done", "head": "abc"});
    let mut fake = Fake::new(vec![
        out("@@started\n"),
        out("@@running\n"),
        out(&format!("@@done\n{attached}\n")),
        forked("s-2"),
    ]);
    let answer = run(&mut fake, &cd(&["s-1", "--repo", "acme/api", "--ref", "main"]), "vm-1")
        .expect("moved");
    assert_eq!(answer["cwd"], "/home/cmux/chats/s-1/api");
    assert_eq!(answer["repo"], attached);
    assert_eq!(answer["session_id"], "s-2");
    assert_eq!(fake.paused, POLL_PAUSE);
    let start = &fake.scripts[0];
    assert!(
        start.contains(
            "\"$1\" --session cloud cloud repo add --session s-1 --repo acme/api --ref main"
        ),
        "{start}"
    );
    assert!(start.contains("nohup sh"), "{start}");
    assert!(start.contains("s-1--acme_api--main"), "{start}");
    assert!(fake.scripts[3].contains("--cwd /home/cmux/chats/s-1/api"), "{}", fake.scripts[3]);
}

/// The read-back on a Cloud machine: a bare `cmux-tui cloud repo add` there reached session
/// `main`, which no Cloud machine runs, and answered `repo.unavailable` ("Connect to the Cloud
/// machine and retry: No such file or directory"). Add repository is the machine daemon's own,
/// session `cloud`.
#[test]
fn the_machines_add_repository_reaches_its_own_daemon_not_session_main() {
    let words = guest_repo_add("s-1", "acme/api", Some("main"));
    let Ok((global, command)) = crate::cli::parse_globals(&words) else { panic!("{words:?}") };
    assert_eq!(
        command,
        strings(&[
            "cloud",
            "repo",
            "add",
            "--session",
            "s-1",
            "--repo",
            "acme/api",
            "--ref",
            "main"
        ])
    );
    let (socket, _) =
        crate::cli::wire::resolve_socket_with_env(&global, |_| None).expect("a socket");
    assert_eq!(socket, cmux_tui_core::server::try_default_socket_path("cloud").expect("cloud"));
    assert_ne!(socket, cmux_tui_core::server::try_default_socket_path("main").expect("main"));

    // An agent's own `CMUX_TUI_SOCKET` on the machine does not pull it elsewhere either.
    let (socket, _) = crate::cli::wire::resolve_socket_with_env(&global, |name| {
        (name == "CMUX_TUI_SOCKET").then(|| "/tmp/elsewhere.sock".into())
    })
    .expect("a socket");
    assert_eq!(socket, cmux_tui_core::server::try_default_socket_path("cloud").expect("cloud"));
    assert_eq!(guest_repo_add("s-1", "acme/api", None).len(), 9);
}

#[test]
fn add_repositorys_refusal_is_the_answer_and_nothing_forks() {
    let refusal = json!({"code": "repo.needs_github", "message": "Connect GitHub in the card.",
                         "install_url": "https://github.com/apps/x/installations/new"});
    let mut fake = Fake::new(vec![out("@@started\n"), out(&format!("@@done\n{refusal}\n"))]);
    let error = run(&mut fake, &cd(&["s-1", "--repo", "acme/api"]), "vm-1").expect_err("refused");
    assert_eq!(error["code"], "repo.needs_github");
    assert_eq!(error["details"]["answer"]["install_url"], refusal["install_url"]);
    assert_eq!(fake.scripts.len(), 2);
}

#[test]
fn a_clone_past_the_timeout_says_to_run_again_and_a_lost_one_says_so() {
    let mut answers = vec![out("@@started\n")];
    answers.extend((0..10).map(|_| out("@@running\n")));
    let mut fake = Fake::new(answers);
    let slow = cd(&["s-1", "--repo", "acme/api", "--timeout", "10"]);
    let error = run(&mut fake, &slow, "vm-1").expect_err("pending");
    assert_eq!(error["code"], "chat_cd.repo_pending");

    let mut fake = Fake::new(vec![out("@@started\n"), out("@@lost\n")]);
    let error = run(&mut fake, &cd(&["s-1", "--repo", "acme/api"]), "vm-1").expect_err("lost");
    assert_eq!(error["code"], "chat_cd.repo_lost");
}

#[test]
fn a_fork_the_machine_refuses_names_its_words() {
    let mut fake = Fake::new(vec![
        out("@@folder\n/w\n"),
        out("@@fork\nError: codex cannot fork a chat\n@@exit 1"),
    ]);
    let error = run(&mut fake, &cd(&["s-1", "/w"]), "vm-1").expect_err("refused");
    assert_eq!(error["code"], "chat_cd.fork_failed");
    let message = error["message"].as_str().unwrap_or_default();
    assert!(message.contains("cannot fork"), "{message}");
}

#[test]
fn chat_cd_is_not_a_chat_start_with_the_prompt_cd() {
    assert!(crate::cli::chat_start::OTHER_VERBS.contains(&"cd"));
}

/// Leo (2026-11-09): a folderless Cloud chat picks its repository later. Such a chat runs in the
/// fresh folder its machine made (`~/chats/<chat>`); `cmux chat cd` never reads that folder, so a
/// cd from it is the same two steps as from any folder: the target is checked, then the chat forks
/// into it. `~` is the machine's home, the folder a folderless chat's `/cd ~/...` names too.
#[test]
fn a_folderless_chat_cds_to_a_folder_on_its_machine() {
    let mut fake = Fake::new(vec![out("@@folder\n/home/cmux\n"), forked("s-2")]);
    let answer = run(&mut fake, &cd(&["peer-7", "~"]), "vm-1").expect("moved");
    assert_eq!(answer["cwd"], "/home/cmux");
    assert_eq!(answer["forked_from"], "peer-7");
    assert_eq!(answer["follow_up"]["cd"], "cmux chat cd s-2 DIR|--repo OWNER/NAME");
    assert_eq!(fake.scripts.len(), 2, "{:?}", fake.scripts);
    assert!(fake.scripts.iter().all(|script| !script.contains("/chats/")), "{:?}", fake.scripts);
    assert!(fake.scripts[1].contains("acp session fork peer-7 --cwd /home/cmux --json"));
}
