use super::*;

#[test]
fn unanswered_mints_are_typed_with_their_cause_in_the_message() {
    for (cause, expected) in [
        (RecvTimeoutError::Timeout, RendererGrantUnavailable::Timeout),
        (RecvTimeoutError::Disconnected, RendererGrantUnavailable::Disconnected),
    ] {
        let error = mint_failure(
            ControlRequestUnanswered { request_kind: MessageKind::MintCapability, cause }.into(),
        );
        let failure = error.downcast_ref::<RendererGrantFailure>().expect("typed failure");
        assert_eq!(failure.unavailable(), expected);
        assert_eq!(
            error.to_string(),
            format!(
                "terminal host did not mint renderer grant: terminal host did not \
                 acknowledge MintCapability: {cause}"
            )
        );
    }
    let broken = std::io::Error::from(std::io::ErrorKind::BrokenPipe);
    let error = mint_failure(broken.into());
    assert_eq!(
        error.downcast_ref::<RendererGrantFailure>().map(RendererGrantFailure::unavailable),
        Some(RendererGrantUnavailable::Disconnected)
    );
    let exhausted = mint_failure(anyhow::anyhow!("terminal host control request id exhausted"));
    assert!(exhausted.downcast_ref::<RendererGrantFailure>().is_none());
    assert_eq!(
        exhausted.to_string(),
        "terminal host did not mint renderer grant: terminal host control request id exhausted"
    );
}
