use super::*;

#[test]
fn both_codecs_round_trip_and_zstd_wins_on_repeated_records() {
    let record = format!(
        r#"{{"kind":"personal.session.put","payload":{{"capabilities":{}}}}}"#,
        serde_json::to_string(&(0..280).map(|i| format!("cap-{i}-v1")).collect::<Vec<_>>())
            .unwrap()
    );
    let json = format!("[{}]", vec![record; 1024].join(","));
    let zstd = encode(json.as_bytes()).unwrap();
    let mut gzip = flate2::GzBuilder::new().mtime(0).write(Vec::new(), flate2::Compression::fast());
    std::io::Write::write_all(&mut gzip, json.as_bytes()).unwrap();
    let gzip = gzip.finish().unwrap();
    println!(
        "segment_codec: json={} gzip-json-v1={} zstd-json-v1={}",
        json.len(),
        gzip.len(),
        zstd.len()
    );
    assert_eq!(decode(ZSTD_JSON_V1, &zstd, json.len()).unwrap(), json.as_bytes());
    assert_eq!(decode(GZIP_JSON_V1, &gzip, json.len()).unwrap(), json.as_bytes());
    assert!(zstd.len() * 20 < gzip.len());
    // A stream longer than its stated length comes back one byte long.
    assert_eq!(decode(ZSTD_JSON_V1, &zstd, 10).unwrap().len(), 11);
    assert!(decode("brotli-json-v1", &zstd, json.len()).is_err());
}
