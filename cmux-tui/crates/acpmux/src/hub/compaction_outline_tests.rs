use super::*;

/// A pack that goes on past a summary (a `fresh` read packed further): the summary's outline
/// names the turns through the summary's line and nothing after it.
#[test]
fn an_outline_from_a_pack_that_goes_on_past_the_summary_ends_at_the_summary() {
    let dir = tempfile::tempdir().unwrap();
    let lines = [
        r#"{"seq":1,"at":10,"dir":"mux","kind":"turn_started","msg":{"promptLine":"one"}}"#,
        r#"{"seq":2,"at":11,"dir":"in","kind":"agent_message_chunk","msg":{"params":{"update":{"content":{"text":"done"}}}}}"#,
        r#"{"seq":3,"at":12,"dir":"mux","kind":"turn_started","msg":{"promptLine":"compact"}}"#,
        r#"{"seq":4,"at":13,"dir":"in","kind":"compaction_summary","msg":{"text":"summary"}}"#,
        r#"{"seq":5,"at":14,"dir":"in","kind":"agent_message_chunk","msg":{"params":{"update":{"content":{"text":"after"}}}}}"#,
        r#"{"seq":6,"at":15,"dir":"mux","kind":"turn_started","msg":{"promptLine":"three"}}"#,
        r#"{"seq":7,"at":16,"dir":"in","kind":"agent_message_chunk","msg":{"params":{"update":{"content":{"text":"later"}}}}}"#,
    ];
    let file = dir.path().join("history.ndjson");
    std::fs::write(&file, lines.join("\n") + "\n").unwrap();
    let store = pack::Store::new(dir.path().join("store"));
    let (manifest, _) =
        pack::pack(&store, "chat", &[file], &pack::Params::default(), false).unwrap();
    assert_eq!(packed_through(&manifest), 7);
    let record = outline_record(&pack::Pack::with_manifest(&store, manifest), "chat", 4).unwrap();
    assert_eq!(record["lastLine"], 3);
    let turns = record["turns"].as_array().unwrap();
    assert_eq!(turns.len(), 2, "{record}");
    assert_eq!(turns[1]["range"], "chat@2-3");
    assert_eq!(turns[1]["records"], 2);
    assert_eq!(record["omitted"], 0);
}
