use super::*;

#[test]
fn confirmed_input_errors_do_not_expose_internal_details() {
    let private = "internal socket /private/terminal.sock token=secret-test-value";
    for kind in [
        std::io::ErrorKind::InvalidInput,
        std::io::ErrorKind::WouldBlock,
        std::io::ErrorKind::Unsupported,
        std::io::ErrorKind::BrokenPipe,
    ] {
        let failure =
            crate::surface::ConfirmedInputFailure::Known(std::io::Error::new(kind, private));
        let ActionFailure::Known(error) = confirmed_input_error("terminal.input.write", failure)
        else {
            panic!("known failure changed delivery classification");
        };
        assert_eq!(error.code, "operation.failed");
        assert!(error.message.starts_with("terminal_input_"));
        assert_eq!(error.details["reason"], error.message);
        assert!(!error.message.contains(private));
        assert!(!error.details.to_string().contains(private));
        assert_eq!(error.details["operation"], "terminal.input.write");
    }
    let failure =
        crate::surface::ConfirmedInputFailure::Indeterminate(std::io::Error::other(private));
    let ActionFailure::Indeterminate(reason) =
        confirmed_input_error("terminal.input.write", failure)
    else {
        panic!("uncertain delivery changed classification");
    };
    assert!(!reason.contains(private));
}
