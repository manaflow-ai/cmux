//! A redrawing TUI costs no journal record at all. An agent TUI waiting for
//! input redraws its cursor about 40 times a second; each 43-byte redraw was
//! one `terminal.output` record and one fullfsync commit, about 21-28 MB/s of
//! disk writes on a NIGHTLY daemon with three agent terminals (macOS
//! disk-write reports, 2026-10-20). Coalescing (#22811) bounded that to a
//! few records per second; output now never enters the journal
//! (cmux-tui-core output_store.rs, tests in host_death/output_store.rs).

use super::*;

const REDRAWS: usize = 100;

#[test]
fn redrawing_terminal_journals_no_output_records() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("journal-output-coalescing");
    let workspace =
        &create_empty_workspace(&harness.socket, "coalesce-workspace", "Journal coalescing");
    let script = format!(
        "i=0; while [ $i -lt {REDRAWS} ]; do \
         printf '\\033[?2026h\\033[39m\\033[49m\\033[0m\\033[94;3H\\033[?25h\\033[?2026l'; \
         sleep 0.01; i=$((i+1)); done"
    );
    let run = resource_request(
        &harness.socket,
        "coalesce-run",
        "workspace.run",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "workspace":workspace,
            "argv":["/bin/sh","-c",script],
        }),
        Some("coalesce-run"),
    );
    let terminal = run["value"]["terminal_id"].as_str().unwrap().to_string();

    let stream = transport::connect(&harness.socket).unwrap();
    stream.set_read_timeout(Some(test_timeout(Duration::from_secs(10)))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(
        writer,
        "{}",
        serde_json::json!({
            "protocol":"cmux.protocol/2",
            "type":"request",
            "id":"coalesce-subscribe",
            "operation":"session.journal.subscribe",
            "params":{
                "machine":"current",
                "session":"current",
                "stream_id":"stream_22222222222242228222222222222222",
                "start":"beginning",
                "filter":{
                    "kinds":["terminal.output","terminal.exited"],
                    "subjects":[{"kind":"terminal","id":terminal}],
                    "max_sensitivity":"sensitive",
                },
            },
        })
    )
    .unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let opened: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(opened["ok"], true, "journal subscription failed: {opened}");

    let mut records = 0_usize;
    loop {
        line.clear();
        reader.read_line(&mut line).expect("journal stream ended before the terminal exited");
        let envelope: serde_json::Value = serde_json::from_str(&line).unwrap();
        let record = &envelope["item"];
        match record["kind"].as_str().unwrap() {
            "terminal.output" => records += 1,
            "terminal.exited" => break,
            other => panic!("unexpected journal record {other}: {record}"),
        }
    }
    assert_eq!(records, 0, "{REDRAWS} redraws took {records} terminal.output records");
}
