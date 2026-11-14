/// A control one pipe leaves open never hides the other pipe's lines.
#[test]
fn a_control_left_open_on_stdout_does_not_hide_stderr() {
    let script = "printf '\\033Psecret'; printf 'error: not found\\n' >&2; exit 1";
    let (ok, text) = super::run(
        &["/bin/sh".to_owned(), "-c".to_owned(), script.to_owned()],
        &std::collections::BTreeMap::new(),
        std::time::Duration::from_secs(10),
    )
    .unwrap();
    assert!(!ok);
    let lines: Vec<String> =
        crate::stderr::clean_stderr_lines(&text).into_iter().filter(|l| !l.is_empty()).collect();
    assert_eq!(lines, vec!["error: not found"], "{text:?}");
}
