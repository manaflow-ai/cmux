//! A cmux NIGHTLY install, again and again, while agents work: each install replaces the binary
//! every agent host runs from and starts `daemon run --take-over`, which asks the running daemon
//! to hand the home over. Several chats sit inside a running tool call, the person queues more
//! prompts behind each before every install, and clients keep dialing the socket throughout. No
//! agent may die at a take-over (the same process, adopted each time), the running tool call must
//! finish once, and every queued prompt must reach its agent exactly once, in order, counted at
//! the agent itself (`FAKE_WIRE_LOG`) as well as in the session log.
//!
//! Each install starts two take-overs: the replaced daemon's own swap starts one
//! (`daemon/exe_swap.rs`) and the installer starts the other. Before, the start that lost the race
//! asked only the first holder and then waited forever on the one that won: the fourth install of
//! a fleet run hung here with three daemons up (2026-11-20).
//!
//! Leo: "BRO CANT YOU JUST LIKE SUSPEND SHIT AFTER A TOOL CALL/TURN THEN JUST GO AND AUTOUPDATE".

use super::*;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

const CHATS: usize = 4;
const INSTALLS: usize = 4;

/// The update as nightly-update does it: the old file moves to a backup, a new build takes the
/// path (a new file, so each host started from the path now runs a replaced binary).
fn install_over(path: &Path) {
    std::fs::rename(path, path.with_extension("backup")).unwrap();
    std::fs::copy(daemon_env::bin(), path).unwrap();
}

/// The fake agents' wire log: every line each agent read.
fn wire(path: &Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

fn queued_text(chat: usize, install: usize) -> String {
    format!("queued c{chat} i{install}")
}

/// Status requests on the socket until `stop`, each on a new connection, as the app's and the
/// CLI's dials keep coming during an install. A dial or an answer that fails (the old daemon's
/// last moment) is not counted; the count of answers is.
fn dial_load(socket: PathBuf, stop: Arc<AtomicBool>, answered: Arc<AtomicUsize>) {
    use std::io::Write;
    while !stop.load(Ordering::Relaxed) {
        if let Ok(mut s) = std::os::unix::net::UnixStream::connect(&socket) {
            let _ = s.set_read_timeout(Some(Duration::from_secs(5)));
            let line = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/status", "params": {}});
            if s.write_all(format!("{line}\n").as_bytes()).is_ok() {
                let mut reply = String::new();
                if BufReader::new(&s).read_line(&mut reply).is_ok_and(|n| n > 0)
                    && reply.contains("\"result\"")
                {
                    answered.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// A connection to the daemon at `socket`, dialed again while none listens there (the moment
/// between one daemon's stop and the next one's bind).
async fn dial(socket: &Path, deadline: Instant) -> Rpc {
    loop {
        match tokio::net::UnixStream::connect(socket).await {
            Ok(s) => {
                let (rd, wr) = s.into_split();
                return Rpc { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 };
            }
            Err(e) => assert!(Instant::now() < deadline, "no daemon at {}: {e}", socket.display()),
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Queues prompt `id` behind `session`'s running turn the way the app sends one: a send whose
/// queued record does not show up (it reached a daemon that was handing the home over) is sent
/// again on a new connection with `resend`, under the same prompt id. The daemon must keep one
/// copy. The last connection stays open, as the app's does through an install.
async fn queue(daemon: &Daemon, session: &str, id: &str, text: &str) -> Rpc {
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut meta = json!({"promptId": id});
    loop {
        let mut rpc = dial(&daemon.socket, deadline).await;
        rpc.send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
                   "_meta": {"acpmux": meta}}),
        )
        .await;
        let look = Instant::now() + Duration::from_secs(5);
        while Instant::now() < look {
            let queued = daemon
                .events(session)
                .iter()
                .any(|e| e["kind"] == "queued" && e["msg"]["promptId"] == id);
            if queued {
                return rpc;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(Instant::now() < deadline, "{session}: prompt {id} was never queued");
        meta["resend"] = json!(true);
    }
}

/// The step the test is at, and when it began. A step that takes longer than [`STUCK`] is a
/// hang: the watchdog prints the step, the processes under the home and the home's logs, then
/// ends the test process (a hang would otherwise hold the run until the job's own timeout).
struct Step(std::sync::Mutex<(String, Instant)>);

// timeout: test-only hang detector; every step here takes seconds.
const STUCK: Duration = Duration::from_secs(90);

impl Step {
    fn at(&self, what: String) {
        eprintln!("take_over_under_load: {what}");
        *self.0.lock().unwrap() = (what, Instant::now());
    }
}

/// Ends the watchdog when the test ends, by a failed assertion too: the watchdog ends the whole
/// test process, so in a process shared with other tests it must never outlive its own test.
struct DoneOnDrop(Arc<AtomicBool>);

impl Drop for DoneOnDrop {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Relaxed);
    }
}

fn watchdog(step: Arc<Step>, home: PathBuf, done: Arc<AtomicBool>) {
    while !done.load(Ordering::Relaxed) {
        std::thread::sleep(Duration::from_millis(500));
        let (what, since) = step.0.lock().unwrap().clone();
        if since.elapsed() < STUCK {
            continue;
        }
        eprintln!("take_over_under_load: STUCK for {:?} at: {what}", since.elapsed());
        let ps =
            std::process::Command::new("ps").args(["-eo", "pid,ppid,stat,etime,args"]).output();
        if let Ok(ps) = ps {
            let home = home.display().to_string();
            for line in String::from_utf8_lossy(&ps.stdout).lines() {
                if line.contains(&home) || line.contains("acpmux") || line.contains("fake_agent") {
                    eprintln!("  ps: {line}");
                }
            }
        }
        for entry in std::fs::read_dir(&home).into_iter().flatten().flatten() {
            let path = entry.path();
            eprintln!("  home: {}", path.display());
            if path.extension().is_some_and(|e| e == "log") {
                let text = std::fs::read_to_string(&path).unwrap_or_default();
                let tail: Vec<&str> = text.lines().rev().take(80).collect();
                for line in tail.into_iter().rev() {
                    eprintln!("    {line}");
                }
            }
        }
        std::process::exit(101);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn nightly_take_overs_mid_tool_call_keep_agents_and_run_each_queued_prompt_once() {
    let mut daemon = Daemon::new("tvload", "approve-all");
    daemon.sigterm();
    let exe = daemon.home.join("bin").join("acpmux");
    std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
    std::fs::copy(daemon_env::bin(), &exe).unwrap();
    daemon.exe = exe.clone();
    let log = daemon.home.join("wire.jsonl");
    let wire_env = format!("FAKE_WIRE_LOG={}", log.display());
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["/usr/bin/env", wire_env, "python3", FAKE]}},
               "defaultHarness": "fake", "permissionPolicy": "approve-all"})
        .to_string(),
    )
    .unwrap();
    let step = Arc::new(Step(std::sync::Mutex::new(("start".into(), Instant::now()))));
    let done = Arc::new(AtomicBool::new(false));
    let _done_on_drop = DoneOnDrop(done.clone());
    let dog = {
        let (step, home, done) = (step.clone(), daemon.home.clone(), done.clone());
        std::thread::spawn(move || watchdog(step, home, done))
    };
    daemon.start();

    // Every chat is inside a tool call that waits on its FIFO.
    step.at("chats start their tool calls".into());
    let mut chats: Vec<(String, PathBuf)> = Vec::new();
    let mut clients = Vec::new();
    for i in 0..CHATS {
        let session = new_session(&daemon).await;
        let gate = daemon.home.join(format!("g{i}"));
        make_fifo(&gate);
        let mut client = daemon.rpc().await;
        client
            .send(
                "session/prompt",
                json!({"sessionId": session,
                       "prompt": [{"type": "text", "text": format!("work-gate: {}", gate.display())}],
                       "_meta": {"acpmux": {"promptId": format!("p-{i}")}}}),
            )
            .await;
        clients.push(client);
        chats.push((session, gate));
    }
    for (session, _) in &chats {
        daemon.wait_event(session, "the running tool call", |e| e["kind"] == "tool_call");
    }
    drop(clients);
    let harness: Vec<i64> =
        chats.iter().map(|(s, _)| daemon.host_record(s)["harness_pid"].as_i64().unwrap()).collect();

    let stop = Arc::new(AtomicBool::new(false));
    let answered = Arc::new(AtomicUsize::new(0));
    let load = {
        let (socket, stop, answered) = (daemon.socket.clone(), stop.clone(), answered.clone());
        std::thread::spawn(move || dial_load(socket, stop, answered))
    };

    for install in 0..INSTALLS {
        // The person queues one more prompt behind each running turn, right before the install.
        step.at(format!("install {install}: queue prompts"));
        let mut held = Vec::new();
        for (i, (session, _)) in chats.iter().enumerate() {
            let id = format!("q-{i}-{install}");
            held.push(queue(&daemon, session, &id, &queued_text(i, install)).await);
        }

        install_over(&exe);
        step.at(format!("install {install}: take-over"));
        daemon.take_over();
        drop(held);
        step.at(format!("install {install}: adoption"));
        for (i, pid) in harness.iter().enumerate() {
            assert!(alive(*pid), "install {install}: chat {i}'s agent died at the take-over");
        }
        for (session, _) in &chats {
            let deadline = Instant::now() + Duration::from_secs(30);
            while daemon.events(session).iter().filter(|e| e["kind"] == "host_adopted").count()
                < install + 1
            {
                assert!(Instant::now() < deadline, "install {install}: {session} never adopted");
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
        // Nothing queued ran while the tool call still runs.
        for (i, (session, _)) in chats.iter().enumerate() {
            let ran = daemon.events(session).into_iter().filter(|e| {
                e["kind"] == "user_message"
                    && e["msg"]["promptId"].as_str().is_some_and(|id| id.starts_with("q-"))
            });
            assert_eq!(ran.count(), 0, "install {install}: chat {i} ran a queued prompt mid-turn");
        }
    }

    // Each tool call finishes; the queued prompts run after it.
    step.at("tool calls finish, queued prompts run".into());
    for (_, gate) in &chats {
        let mut writer = std::fs::OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(gate)
            .expect("the agent still waits on its gate");
        std::io::Write::write_all(&mut writer, b"go").unwrap();
    }
    for (i, (session, _)) in chats.iter().enumerate() {
        for install in 0..INSTALLS {
            let echo = format!("echo: {}", queued_text(i, install));
            daemon.wait_event(session, &echo, |e| chunk(e, &echo));
        }
    }
    step.at("the dial load stops".into());
    stop.store(true, Ordering::Relaxed);
    load.join().unwrap();
    done.store(true, Ordering::Relaxed);
    dog.join().unwrap();
    assert!(
        answered.load(Ordering::Relaxed) > 0,
        "no status dial was answered during the installs"
    );
    // Test-only fixed wait: a late second copy would come right behind the first.
    tokio::time::sleep(Duration::from_secs(2)).await;

    let read = wire(&log);
    for (i, ((session, _), pid)) in chats.iter().zip(&harness).enumerate() {
        let events = daemon.events(session);
        let count = |pred: &dyn Fn(&Value) -> bool| events.iter().filter(|e| pred(e)).count();
        assert_eq!(
            count(&|e: &Value| chunk(e, "worked")),
            1,
            "chat {i}: the tool call: {events:#?}"
        );
        assert_eq!(
            count(&|e: &Value| e["kind"] == "tool_call"
                && e["msg"].pointer("/params/update/toolCallId") == Some(&json!("wg-1"))),
            1,
            "chat {i}: its tool call started again: {events:#?}"
        );
        let order: Vec<&str> = events
            .iter()
            .filter(|e| e["kind"] == "user_message")
            .filter_map(|e| e["msg"]["promptId"].as_str())
            .filter(|id| id.starts_with("q-"))
            .collect();
        let want: Vec<String> = (0..INSTALLS).map(|n| format!("q-{i}-{n}")).collect();
        assert_eq!(order, want, "chat {i}: queued prompts ran out of order or more than once");
        for install in 0..INSTALLS {
            let echo = format!("echo: {}", queued_text(i, install));
            assert_eq!(count(&|e: &Value| chunk(e, &echo)), 1, "chat {i}: {echo}: {events:#?}");
        }
        let first = read.iter().any(|l| l["pid"] == json!(pid) && l["method"] == "session/prompt");
        assert!(first, "chat {i}: its first agent never read the running prompt");
    }
    // At the agents: the wire log's session ids do not tell the chats apart, so it counts across
    // them all: the running prompt and every queued one, each read by an agent exactly once,
    // whichever agent process ran it.
    let prompts = read.iter().filter(|l| l["method"] == "session/prompt").count();
    assert_eq!(prompts, CHATS * (1 + INSTALLS), "the agents read {prompts} prompts");

    // The daemon that serves now may be one the replaced daemon's own swap started, not the
    // test's child: end it as the harness ends its own.
    let holder = std::fs::read_to_string(daemon.home.join("daemon.lock"))
        .ok()
        .and_then(|t| t.lines().next()?.trim().parse::<i32>().ok());
    if let Some(pid) = holder
        && daemon.child.as_ref().is_none_or(|c| c.id() as i32 != pid)
    {
        // SAFETY: signalling the daemon this test's home runs.
        unsafe { libc::kill(pid, libc::SIGTERM) };
        assert!(
            gone_within(pid.into(), Duration::from_secs(30)),
            "the serving daemon outlived its stop"
        );
    }
}
