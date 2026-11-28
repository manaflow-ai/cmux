use super::*;

#[test]
fn a_program_name_with_a_nul_is_refused_without_exec() {
    let error = exec_replace(Path::new("bad\0name"), ["x"], [("K", "V")]);
    assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
}

#[test]
fn a_missing_program_returns_the_exec_error() {
    let error = exec_replace(
        Path::new("/nonexistent/cmux-process-exec-test"),
        std::iter::empty::<&str>(),
        std::iter::empty::<(&str, &str)>(),
    );
    assert_eq!(error.raw_os_error(), Some(libc::ENOENT));
}
