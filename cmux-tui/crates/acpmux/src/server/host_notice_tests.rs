use super::*;

#[test]
fn a_notice_is_one_bounded_line() {
    assert_eq!(
        line("  Machine grew to 4 vCPU / 8 GiB ").unwrap(),
        "Machine grew to 4 vCPU / 8 GiB"
    );
    assert!(line("").is_err());
    assert!(line("a\nb").is_err());
    assert!(line(&"x".repeat(MAX_CHARS)).is_ok());
    assert!(line(&"x".repeat(MAX_CHARS + 1)).is_err());
}
