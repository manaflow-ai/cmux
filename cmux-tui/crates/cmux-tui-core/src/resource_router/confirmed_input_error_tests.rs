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

#[test]
fn a_full_input_port_is_written_again_once_it_drains() {
    let tries = std::cell::Cell::new(0);
    let out = confirmed_write_while_busy(|| {
        tries.set(tries.get() + 1);
        if tries.get() < 3 {
            Err(crate::surface::ConfirmedInputFailure::Known(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "terminal.input_busy",
            )))
        } else {
            Ok(())
        }
    });
    assert!(out.is_ok());
    assert_eq!(tries.get(), 3);
}

#[test]
fn an_uncertain_or_lasting_input_failure_is_not_written_again() {
    let failures: [fn() -> crate::surface::ConfirmedInputFailure; 2] = [
        || crate::surface::ConfirmedInputFailure::Indeterminate(std::io::Error::other("ack lost")),
        || {
            crate::surface::ConfirmedInputFailure::Known(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "too large",
            ))
        },
    ];
    for failure in failures {
        let tries = std::cell::Cell::new(0);
        let out = confirmed_write_while_busy(|| {
            tries.set(tries.get() + 1);
            Err(failure())
        });
        assert!(out.is_err());
        assert_eq!(tries.get(), 1);
    }
}
