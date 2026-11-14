use super::*;

#[test]
fn reads_the_seeds_copys_and_fallbacks_lines_and_nothing_else() {
    let upload =
        parse(r#"{"progress":{"phase":"upload","bytes_done":5,"bytes_total":9}}"#).unwrap();
    assert_eq!(
        upload,
        Progress {
            phase: "upload".into(),
            bytes_done: Some(5),
            bytes_total: Some(9),
            ..Progress::default()
        }
    );
    let copy =
        parse(r#"{"progress":{"files_done":1,"files_total":3,"bytes_done":4,"bytes_total":8}}"#)
            .unwrap();
    assert_eq!(
        (copy.phase.as_str(), copy.files_done, copy.files_total),
        ("copy", Some(1), Some(3))
    );
    let fallback =
            parse(r#"{"progress":{"phase":"copy","fallback_code":"seed.needs_github","install_url":"https://github.com/apps/cmux"}}"#).unwrap();
    assert_eq!(fallback.fallback_code.as_deref(), Some("seed.needs_github"));
    assert_eq!(fallback.install_url.as_deref(), Some("https://github.com/apps/cmux"));
    assert_eq!(parse("warning: something"), None);
    assert_eq!(parse(r#"{"ok":true}"#), None);
    assert_eq!(parse(r#"{"progress":{"bytes_done":1}}"#), None, "no phase and no files");
}

#[test]
fn throttles_but_a_phase_change_always_goes_and_a_fallback_stays_on_the_copy() {
    let mut reader = Reader::default();
    let mut seen = Vec::new();
    for (line, now) in [
        (r#"{"progress":{"phase":"upload","bytes_done":1,"bytes_total":9}}"#, 0.0),
        (r#"{"progress":{"phase":"upload","bytes_done":2,"bytes_total":9}}"#, 10.0),
        (r#"{"progress":{"phase":"copy","fallback_code":"not_git"}}"#, 20.0),
        (r#"{"progress":{"files_done":1,"files_total":2}}"#, 30.0),
        (r#"{"progress":{"files_done":2,"files_total":2}}"#, 300.0),
    ] {
        seen.extend(reader.read(line, now));
    }
    assert_eq!(
        seen.iter().map(|progress| progress.phase.as_str()).collect::<Vec<_>>(),
        ["upload", "copy", "copy"]
    );
    assert_eq!(seen.last().unwrap().fallback_code.as_deref(), Some("not_git"));
    assert_eq!(seen.last().unwrap().files_done, Some(2));
}
