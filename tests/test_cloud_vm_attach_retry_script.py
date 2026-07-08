from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_cloud_vm_terminal_startup_uses_persistent_attach_retries():
    workspace = (ROOT / "Sources" / "Workspace.swift").read_text()
    restore = (ROOT / "Sources" / "SessionRemoteWorkspaceSnapshot+Restore.swift").read_text()
    cli = (ROOT / "CLI" / "cmux.swift").read_text()

    for source in (workspace, restore, cli):
        assert 'CMUX_SSH_RECONNECT_LIMIT=\\"${CMUX_SSH_RECONNECT_LIMIT:-86400}\\"' in source
        assert (
            'CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT=\\"${CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT:-$CMUX_SSH_RECONNECT_LIMIT}\\"'
            in source
        )
        assert (
            'CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS=\\"${CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS:-$CMUX_SSH_RECONNECT_DELAY_SECONDS}\\"'
            in source
        )
        assert '\\"$cmux_freestyle_cli\\" --socket \\"$CMUX_SOCKET_PATH\\" vm-pty-attach' in source
        assert "cmux_freestyle_attach" in source


def test_cloud_vm_retry_message_does_not_show_huge_retry_denominator():
    cli = (ROOT / "CLI" / "cmux.swift").read_text()

    assert "Waiting for the local cmux web server" in cli
    assert "Waiting for the Cloud VM service" in cli
    assert "Waiting for the Cloud VM control plane" in cli
    assert "provider control plane" in cli
    assert "local cmux web server is offline" in cli
    assert "cmuxd websocket health check failed" in cli
    assert "operation was aborted" in cli
    assert "requires a cmuxd rpc endpoint" in cli
    assert "let response = try defaultFreestyleAttachInfoWithRetryIfNeeded(" in cli
    assert "private static func retryAttemptLabel(attempt: Int, retryLimit: Int) -> String" in cli
    assert "if retryLimit >= 86_400" in cli


def test_dev_env_preserves_explicit_cloud_vm_image_overrides():
    env_loader = (ROOT / "web" / "scripts" / "load-dev-env.sh").read_text()

    assert 'cmux_existing_freestyle_snapshot_set="${FREESTYLE_SANDBOX_SNAPSHOT+x}"' in env_loader
    assert 'export FREESTYLE_SANDBOX_SNAPSHOT="$cmux_existing_freestyle_snapshot"' in env_loader
    assert 'cmux_existing_e2b_template_set="${E2B_CMUXD_WS_TEMPLATE+x}"' in env_loader
    assert 'export E2B_CMUXD_WS_TEMPLATE="$cmux_existing_e2b_template"' in env_loader
