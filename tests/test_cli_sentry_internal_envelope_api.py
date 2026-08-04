from pathlib import Path


def test_cli_uses_structured_sentry_internal_envelope_api() -> None:
    source = (
        Path(__file__).resolve().parents[1]
        / "CLI"
        / "CLISocketSentryTelemetry.swift"
    ).read_text()

    assert "SentrySDK.internal.envelope.store(envelope)" in source
    assert "PrivateSentrySDKOnly.store(envelope)" not in source
