use super::*;

/// One registry's staged records were mostly `personal.session.put`
/// copies of about 7 KB (2026-11-09); format 2 stored each as is.
#[test]
fn staged_records_round_trip_compressed_with_their_index_fields() {
    let connection = Connection::open_in_memory().unwrap();
    connection.execute_batch(CHUNK_SCHEMA).unwrap();
    let capabilities: Vec<String> = (0..280).map(|i| format!("capability-{i}-v1")).collect();
    let records: Vec<StagedRecord> = (1..=1024_u64)
        .map(|sequence| {
            let record = json!({
                "sequence": sequence,
                "event_id": format!("event_{sequence}"),
                "kind": "personal.session.put",
                "producer": {"kind": "daemon", "id": "cmux-tui"},
                "subjects": [{"kind": "session", "id": "remote-1"}],
                "payload": {"session": {"capabilities": capabilities}},
            });
            (sequence, "personal.session.put".to_owned(), record.to_string().into_bytes(), None)
        })
        .collect();
    let plain: usize = records.iter().map(|record| record.2.len()).sum();
    insert_chunk(&connection, &records).unwrap();
    let stored: i64 = connection
        .query_row(
            "SELECT (SELECT SUM(length(content)) FROM output_cleanup_chunks)
                      + (SELECT SUM(length(index_json)) FROM output_cleanup_records)",
            [],
            |row| row.get(0),
        )
        .unwrap();
    println!("staged_chunk: records=1024 plain_bytes={plain} stored_bytes={stored}");
    assert!(usize::try_from(stored).unwrap() * 20 < plain);
    let mut reader = ChunkReader::new();
    for (sequence, _, bytes, _) in &records {
        assert_eq!(reader.record(&connection, 1, *sequence).unwrap(), bytes.as_slice());
    }
    let (subject, producer): (String, String) = connection
        .query_row(
            "SELECT json_extract(subject.value, '$.id'),
                        json_extract(kept.index_json, '$.producer.kind')
                 FROM output_cleanup_records AS kept,
                      json_each(kept.index_json, '$.subjects') AS subject
                 WHERE kept.sequence = 7",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!((subject, producer), ("remote-1".to_owned(), "daemon".to_owned()));
    assert!(reader.record(&connection, 1, 2048).is_err());
}

/// Live rows stage in (kind, sequence) order, one kind per chunk; the
/// pack reads them by sequence and moves between the kinds' chunks.
#[test]
fn interleaved_kind_chunks_read_back_in_sequence_order() {
    let connection = Connection::open_in_memory().unwrap();
    connection.execute_batch(CHUNK_SCHEMA).unwrap();
    let record = |sequence: u64, kind: &str| -> StagedRecord {
        let json = json!({"sequence": sequence, "kind": kind, "subjects": []});
        (sequence, kind.to_owned(), json.to_string().into_bytes(), None)
    };
    let odd: Vec<_> = (1..=99).step_by(2).map(|s| record(s, "a.kind")).collect();
    let even: Vec<_> = (2..=100).step_by(2).map(|s| record(s, "b.kind")).collect();
    insert_chunk(&connection, &odd).unwrap();
    insert_chunk(&connection, &even).unwrap();
    let mut reader = ChunkReader::new();
    let mut statement = connection
        .prepare("SELECT sequence, chunk FROM output_cleanup_records ORDER BY sequence")
        .unwrap();
    let rows: Vec<(i64, i64)> = statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert_eq!(rows.len(), 100);
    for (sequence, chunk) in rows {
        let sequence = u64::try_from(sequence).unwrap();
        let json: Value =
            serde_json::from_slice(reader.record(&connection, chunk, sequence).unwrap()).unwrap();
        assert_eq!(json["sequence"], json!(sequence));
    }
    assert_eq!(reader.open.len(), 2, "each chunk was inflated once and kept");
}
