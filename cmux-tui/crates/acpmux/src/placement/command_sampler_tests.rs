use super::*;
use serde_json::json;

fn start(id: &str, script: &str, pid: Option<u32>) -> Start {
    Start {
        session: "s1".into(),
        tool_call_id: id.into(),
        repo: "/r".into(),
        script: script.into(),
        background: false,
        agent_pid: pid,
    }
}

fn proc(ppid: u32, start: u64, cpu: u64, rss_bytes: u64) -> Proc {
    Proc { ppid, start, cpu, rss_bytes }
}

fn rows(dir: &tempfile::TempDir) -> Vec<Value> {
    std::fs::read_to_string(dir.path().join("rows.jsonl"))
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

#[test]
fn a_shell_tool_call_starts_and_ends_a_call() {
    let call = json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "kind": "execute",
        "status": "pending", "rawInput": {"command": "cargo test", "run_in_background": true}});
    assert_eq!(start_of(&call), Some(("t1".into(), "cargo test".into(), true)));
    let argv = json!({"sessionUpdate": "tool_call", "toolCallId": "t2", "rawInput": {"command": ["bash", "-lc", "ls"]}});
    assert_eq!(start_of(&argv).map(|s| s.1), Some("bash -lc ls".into()));
    let read = json!({"sessionUpdate": "tool_call", "toolCallId": "t3", "kind": "read", "rawInput": {"command": "x"}});
    assert_eq!(start_of(&read), None, "not a shell call");
    let done =
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"});
    assert_eq!(start_of(&done), None);
    assert_eq!(end_of(&done), Some(("t1", "completed")));
    let running =
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "in_progress"});
    assert_eq!(end_of(&running), None);
}

#[test]
fn a_stat_line_reads_past_a_name_with_spaces_and_parentheses() {
    // pid (comm) state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt
    // utime stime cutime cstime priority nice threads itrealvalue starttime vsize rss ...
    let line = "4242 (my (odd) prog) S 100 4242 4242 0 -1 4194304 10 0 0 0 7 3 20 10 20 0 1 0 555 1000000 25 18446744073709551615";
    let p = parse_stat(line, 4096).unwrap();
    assert_eq!(p, Proc { ppid: 100, start: 555, cpu: 40, rss_bytes: 25 * 4096 });
}

#[test]
fn listening_sockets_are_read_by_inode() {
    let table = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 91234 1 0 100 0 0 10 0
   1: 0100007F:9C40 0100007F:0BB8 01 00000000:00000000 00:00000000 00000000  1000        0 91235 1 0 100 0 0 10 0
";
    let mut into = HashMap::new();
    parse_listening(table, &mut into);
    assert_eq!(into, HashMap::from([(91234, 3000)]), "only state 0A, port 0x0BB8");
}

#[test]
fn a_calls_processes_are_the_branches_that_started_after_it_and_the_latest_call_wins() {
    let dir = tempfile::tempdir().unwrap();
    let shadow = Shadow::new(dir.path().join("rows.jsonl"));
    shadow.begin(start("a", "pnpm run dev", Some(10)), Some(1_000));
    shadow.begin(start("b", "cargo build", Some(10)), Some(2_000));
    let mut procs = Procs::default();
    procs.rows.insert(10, proc(1, 5, 0, 0)); // the agent
    procs.rows.insert(11, proc(10, 50, 9, 1 << 20)); // an MCP server, older than both calls
    procs.rows.insert(20, proc(10, 1_100, 2, 1 << 20)); // call a's shell
    procs.rows.insert(21, proc(20, 2_500, 3, 1 << 20)); // a's child, started after b began: still a's
    procs.rows.insert(30, proc(10, 2_100, 100, 3 << 30)); // call b's shell
    procs.rows.insert(31, proc(30, 2_200, 400, 1 << 30));
    procs.listening.insert(777, 3000);
    procs.sockets.insert(21, vec![777]);
    let procs = std::sync::Mutex::new(Some(procs));
    let read = || procs.lock().unwrap().take();
    shadow.tick(&read);
    {
        let inner = shadow.lock();
        let a = &inner.flights[&("s1".to_owned(), "a".to_owned())];
        let b = &inner.flights[&("s1".to_owned(), "b".to_owned())];
        assert_eq!(a.procs.keys().copied().collect::<BTreeSet<_>>(), BTreeSet::from([20, 21]));
        assert_eq!(b.procs.keys().copied().collect::<BTreeSet<_>>(), BTreeSet::from([30, 31]));
        assert_eq!((a.cpu_ticks, a.ports.iter().copied().collect::<Vec<_>>()), (5, vec![3000]));
        assert_eq!((b.cpu_ticks, b.peak_rss_bytes), (500, 4 << 30));
    }
    // b ends; at the next reading its processes are gone: its row is written and fed back.
    shadow.end("s1", "b", "completed");
    let gone = std::sync::Mutex::new(Some(Procs {
        rows: HashMap::from([(10, proc(1, 5, 0, 0)), (20, proc(10, 1_100, 2, 1 << 20))]),
        ..Default::default()
    }));
    shadow.tick(&|| gone.lock().unwrap().take());
    let written = rows(&dir);
    assert_eq!(written.len(), 1, "{written:?}");
    let row = &written[0];
    assert_eq!(row["toolCallId"], "b");
    assert_eq!(row["class"], "cargo build");
    assert_eq!(row["decision"], "runVm", "cargo build's class default is past 8 / 16");
    assert_eq!(row["rowNumber"], 3);
    assert_eq!(row["status"], "completed");
    assert_eq!(row["usage"]["cpuS"].as_f64().unwrap(), 500.0 / clock_ticks());
    assert_eq!(row["usage"]["peakMemGiB"], 4.0);
    assert_eq!(row["usage"]["outlived"], false);
    assert_eq!(row["predicted"]["source"], "classDefault");
    assert!(row["wallS"].as_f64().is_some());
    // The table now predicts cargo build from its run.
    let p = shadow.lock().table.predict("/r", "cargo build", "cargo build", false);
    assert_eq!((p.source, p.runs), (shadow::Source::History, 1));
    // a is a server: still in flight.
    assert!(shadow.lock().flights.contains_key(&("s1".to_owned(), "a".to_owned())));
}

#[test]
fn a_call_with_no_agent_process_is_written_with_usage_unknown() {
    let dir = tempfile::tempdir().unwrap();
    let shadow = Shadow::new(dir.path().join("rows.jsonl"));
    shadow.begin(start("x", "git status", None), Some(1));
    shadow.end("s1", "x", "failed");
    shadow.tick(&|| Some(Procs::default()));
    let row = &rows(&dir)[0];
    assert_eq!((row["decision"].as_str(), row["rowNumber"].as_u64()), (Some("here"), Some(6)));
    assert!(row["usage"].is_null());
    assert_eq!(row["why"], "usage unknown: no agent process");
    assert_eq!(row["status"], "failed");
}

#[test]
fn a_second_heavy_call_of_the_session_is_placed_on_a_run_vm() {
    let dir = tempfile::tempdir().unwrap();
    let shadow = Shadow::new(dir.path().join("rows.jsonl"));
    shadow.begin(start("t1", "bun test", Some(1)), Some(1));
    shadow.begin(start("t2", "bun test", Some(1)), Some(2));
    let inner = shadow.lock();
    assert_eq!(inner.flights[&("s1".to_owned(), "t1".to_owned())].verdict.decision, Decision::Grow);
    let second = &inner.flights[&("s1".to_owned(), "t2".to_owned())];
    assert_eq!((second.verdict.decision, second.situation.heavy_running), (Decision::RunVm, 1));
}

#[test]
fn a_restart_refills_the_prediction_table_from_the_rows_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("rows.jsonl");
    std::fs::write(
        &path,
        concat!(
            r#"{"repo":"/r","class":"pytest","wallS":3.0,"usage":{"cpuS":1.5,"peakMemGiB":0.2,"ports":[],"outlived":false}}"#,
            "\n",
            r#"{"repo":"/r","class":"pytest","wallS":4.0,"usage":null}"#,
            "\nnot json\n"
        ),
    )
    .unwrap();
    let shadow = Shadow::new(path);
    shadow.begin(start("t", "pytest -q", Some(1)), Some(1));
    let inner = shadow.lock();
    let f = &inner.flights[&("s1".to_owned(), "t".to_owned())];
    assert_eq!(
        (f.predicted.source, f.predicted.runs, f.predicted.wall_s),
        (shadow::Source::History, 1, Some(3.0))
    );
    assert_eq!((f.verdict.decision, f.verdict.row.number()), (Decision::Here, 1));
}

/// The live sampler on this machine: a call that runs a process that listens and allocates.
#[cfg(target_os = "linux")]
#[test]
fn the_live_sampler_measures_a_real_command_and_its_port() {
    if std::process::Command::new("python3")
        .arg("-c")
        .arg("1")
        .status()
        .map(|s| !s.success())
        .unwrap_or(true)
    {
        eprintln!("no python3: skipped");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let shadow = Shadow::new(dir.path().join("rows.jsonl"));
    // The "agent": a shell that waits a moment and then runs the command, as a harness would.
    let script = "import socket,time\nb=bytearray(64<<20)\ns=socket.socket()\ns.bind(('127.0.0.1',0))\ns.listen()\nt=time.time()\nwhile time.time()-t<1.2: pass\ntime.sleep(1.5)";
    let began = boot_ticks_now();
    let mut agent = std::process::Command::new("sh")
        .arg("-c")
        .arg("sleep 0.1; python3 -c \"$0\"; true")
        .arg(script)
        .spawn()
        .unwrap();
    shadow.begin(start("live", "python3 -m http.server", Some(agent.id())), began);
    for _ in 0..25 {
        shadow.tick_live();
        std::thread::sleep(Duration::from_millis(100));
    }
    shadow.end("s1", "live", "completed");
    let _ = agent.wait();
    shadow.tick_live();
    let row = &rows(&dir)[0];
    assert_eq!(row["decision"], "serveVm", "{row}");
    let usage = &row["usage"];
    assert!(usage["peakMemGiB"].as_f64().unwrap() >= 0.06, "{row}");
    assert!(usage["cpuS"].as_f64().unwrap() >= 0.5, "{row}");
    assert_eq!(usage["ports"].as_array().map(Vec::len), Some(1), "{row}");
}

#[test]
fn a_call_that_ends_between_two_readings_is_unmeasured_not_zero() {
    let dir = tempfile::tempdir().unwrap();
    let shadow = Shadow::new(dir.path().join("rows.jsonl"));
    shadow.begin(start("quick", "echo hi", Some(10)), Some(1_000));
    let only_agent =
        || Some(Procs { rows: HashMap::from([(10, proc(1, 5, 0, 0))]), ..Default::default() });
    shadow.tick(&only_agent);
    shadow.end("s1", "quick", "completed");
    shadow.tick(&only_agent);
    let row = &rows(&dir)[0];
    assert!(row["usage"]["cpuS"].is_null() && row["usage"]["peakMemGiB"].is_null(), "{row}");
    assert_eq!(row["why"], "usage unmeasured: it ended between two readings");
    // Nothing is learned from it: the class still has no history.
    let p = shadow.lock().table.predict("/r", "echo", "echo hi", false);
    assert_eq!(p.source, shadow::Source::None);
}
