use super::*;

#[test]
fn a_bare_program_name_resolves_on_the_requests_path() {
    let env = vec![b"HOME=/".to_vec(), b"PATH=/nonexistent-cmux-dir:/bin:/usr/bin".to_vec()];
    let resolved = resolve_program(b"sh", &env, b"/").unwrap();
    assert!(resolved.to_bytes().ends_with(b"/sh"), "{resolved:?}");
    assert_eq!(resolve_program(b"/bin/sh", &[], b"/").unwrap().to_bytes(), b"/bin/sh");
    let missing = resolve_program(b"cmux-no-such-program", &env, b"/").unwrap_err();
    assert_eq!(missing.kind(), io::ErrorKind::NotFound);
}
