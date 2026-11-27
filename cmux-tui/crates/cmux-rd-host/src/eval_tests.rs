use super::*;

#[test]
fn decode_evidence_is_bounded_and_retains_frame_identity() {
    let mut log = DecodeLog::default();
    log.record(7, 12, 34);
    assert_eq!(log.records[0]["frame_id"], 7);
    assert_eq!(log.records[0]["release_us"], 12);
    assert_eq!(log.records[0]["decoded_us"], 34);
    log.records.resize(MAX_TIMINGS, Value::Null);
    log.record(8, 13, 35);
    assert!(log.truncated);
    assert_eq!(log.records.len(), MAX_TIMINGS);
}

#[test]
fn quality_requires_matching_timestamp_and_access_unit() {
    let unique =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let dir = std::env::temp_dir().join(format!("cmux-rd-quality-{}-{unique}", std::process::id()));
    std::fs::create_dir(&dir).unwrap();
    let stem = dir.join("42");
    write_new(&stem.with_extension("au"), b"encoded sample").unwrap();
    write_new(&stem.with_extension("source.json"), b"{\"capture_us\":42}").unwrap();
    write_new(&stem.with_extension("source.y8"), &vec![42; WIDTH * HEIGHT]).unwrap();
    let mut quality = Quality {
        dir: dir.clone(),
        #[cfg(target_os = "macos")]
        sources: 0,
        #[cfg(target_os = "macos")]
        last_source_us: None,
        samples: Vec::new(),
    };
    let pixels = vec![43; WIDTH * HEIGHT];
    quality.decoded(7, 43, b"encoded sample", &pixels);
    quality.decoded(7, 42, b"other access unit", &pixels);
    assert!(quality.samples.is_empty());
    quality.decoded(7, 42, b"encoded sample", &pixels);
    assert_eq!(quality.samples.len(), 1);
    assert_eq!(quality.samples[0]["identity_verified"], true);
    assert_eq!(quality.samples[0]["frame_id"], 7);
    assert_eq!(quality.samples[0]["mse"], 1.0);
    // Every path was created by this test in its exclusive directory.
    for extension in ["au", "source.json", "source.y8", "decoded.y8", "quality.json"] {
        std::fs::remove_file(stem.with_extension(extension)).unwrap();
    }
    std::fs::remove_dir(dir).unwrap();
}

#[test]
fn quality_crop_honors_stride_and_rejects_short_planes() {
    let mut pixels = vec![0; 300 * 128];
    pixels[64 * 300 + 128] = 99;
    let crop = roi(&pixels, 300).unwrap();
    assert_eq!(crop.len(), 8192);
    assert_eq!(crop[0], 99);
    assert!(roi(&pixels[..100], 300).is_none());
    assert!(roi(&pixels, 127).is_none());
}
