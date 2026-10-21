//! A redrawing TUI costs one journal record per coalescing window, not one
//! per PTY read. An agent TUI waiting for input redraws its cursor about 40
//! times a second; each 43-byte redraw was one `terminal.output` record and
//! one fullfsync commit, about 21-28 MB/s of disk writes on a NIGHTLY daemon
//! with three agent terminals (macOS disk-write reports, 2026-10-20). The
//! journal must still keep every byte.

use super::*;

/// The cursor redraw an idle agent TUI repeats (from the NIGHTLY journal).
const REDRAW: &[u8] = b"\x1b[?2026h\x1b[39m\x1b[49m\x1b[0m\x1b[94;3H\x1b[?25h\x1b[?2026l";
const REDRAWS: usize = 100;
/// One record per 250 ms window: about 6 for the 1-2 s the program runs.
/// Before coalescing, each of the 100 reads was its own record.
const MAX_RECORDS: usize = 30;

#[test]
fn redrawing_terminal_journals_every_byte_in_coalesced_records() {
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
    let mut output = Vec::new();
    loop {
        line.clear();
        reader.read_line(&mut line).expect("journal stream ended before the terminal exited");
        let envelope: serde_json::Value = serde_json::from_str(&line).unwrap();
        let record = &envelope["item"];
        match record["kind"].as_str().unwrap() {
            "terminal.output" => {
                records += 1;
                output.extend(
                    base64::engine::general_purpose::STANDARD
                        .decode(record["payload"]["data"].as_str().unwrap())
                        .unwrap(),
                );
            }
            "terminal.exited" => break,
            other => panic!("unexpected journal record {other}: {record}"),
        }
    }
    let redraws = output.windows(REDRAW.len()).filter(|window| *window == REDRAW).count();
    assert_eq!(
        (redraws, output.len()),
        (REDRAWS, REDRAWS * REDRAW.len()),
        "the journal lost or changed terminal output bytes"
    );
    assert!(
        records <= MAX_RECORDS,
        "{REDRAWS} redraws took {records} terminal.output records (at most {MAX_RECORDS})"
    );
}
