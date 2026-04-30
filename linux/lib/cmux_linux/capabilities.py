from __future__ import annotations

from typing import Any

from .browser import browser_backend_limits
from .terminal import linux_port_scanner_capability, linux_terminal_renderer_capability

REQUIRED_SUBSYSTEMS = (
    "auth",
    "feed",
    "feedback",
    "remoteDaemon",
    "browser",
    "windows",
    "terminal",
    "packaging",
)

REQUIRED_STATUS_KEYS = ("available", "backend", "mode", "detail")

REQUIRED_FAILURE_CODES = (
    "invalid_params",
    "not_supported",
    "backend_unavailable",
    "transport_error",
)


def status_payload(available: bool, backend: str, mode: str, detail: str, **extra: Any) -> dict[str, Any]:
    return {
        "available": available,
        "backend": backend,
        "mode": mode,
        "detail": detail,
        **extra,
    }


def packaging_formats() -> dict[str, dict[str, Any]]:
    artifact_formats = {
        "tarball": status_payload(
            True,
            "linux/package.sh",
            "artifact",
            "validator_enabled",
            manifest="share/cmux/package-manifest.json",
            validator="linux/tools/validate_package.py",
        ),
        "deb": status_payload(
            True,
            "linux/package-deb.sh",
            "artifact",
            "validator_enabled",
            manifest="share/cmux/package-manifest.json",
            validator="linux/tools/validate_package.py",
        ),
        "appimage": status_payload(
            True,
            "linux/package-appimage.sh",
            "artifact",
            "validator_enabled",
            manifest="share/cmux/package-manifest.json",
            validator="linux/tools/validate_package.py",
        ),
        "rpm": status_payload(
            True,
            "linux/package-rpm.sh",
            "artifact",
            "validator_enabled",
            manifest="share/cmux/package-manifest.json",
            validator="linux/tools/validate_package.py",
        ),
        "flatpak": status_payload(
            True,
            "linux/package-flatpak.sh",
            "artifact",
            "validator_enabled",
            manifest="share/cmux/package-manifest.json",
            validator="linux/tools/validate_package.py",
        ),
    }
    return artifact_formats


def build_subsystem_capabilities(
    *,
    auth_bridge_available: bool,
    auth_detail: str,
    feedback_endpoint_configured: bool,
    remote_daemon: dict[str, Any],
    browser_available: bool,
    browser_backend: str | None,
    window_count: int,
    terminal_backend: str,
) -> dict[str, dict[str, Any]]:
    remote_available = bool(remote_daemon.get("available"))
    remote_state = str(remote_daemon.get("state") or ("installed" if remote_available else "missing"))
    remote_detail = str(remote_daemon.get("detail") or "remote_daemon_not_available_on_linux")
    return {
        "auth": status_payload(
            True,
            "cmux_auth_core_bridge" if auth_bridge_available else "linux_local_state",
            "bridge" if auth_bridge_available else "local_fallback",
            auth_detail,
        ),
        "feed": status_payload(
            True,
            "cmux_workstream_shape",
            "local_ledger",
            "workstream_event_shape_with_runtime_reply_delivery",
        ),
        "feedback": status_payload(
            True,
            "http_upload" if feedback_endpoint_configured else "linux_local_queue",
            "upload" if feedback_endpoint_configured else "queued_fallback",
            "feedback_endpoint_configured" if feedback_endpoint_configured else "feedback_endpoint_unconfigured",
        ),
        "remoteDaemon": status_payload(
            remote_available,
            "cmuxd-remote",
            remote_state,
            remote_detail,
            bundled=bool(remote_daemon.get("bundled")),
            path=remote_daemon.get("path"),
            probe=remote_daemon.get("probe"),
            capabilities=remote_daemon.get("capabilities") or [],
        ),
        "browser": status_payload(
            browser_available,
            browser_backend or "none",
            "webkitgtk" if browser_available else "unavailable",
            "native_webkitgtk_with_backend_limits" if browser_available else "webkitgtk_unavailable",
            backend_limits=browser_backend_limits(),
        ),
        "windows": status_payload(
            True,
            "gtk_application_registry",
            "single_window_registry" if window_count <= 1 else "multi_window",
            "last_window_close_quits_app",
            count=window_count,
            last_window_policy="quit_app",
        ),
        "terminal": status_payload(
            True,
            terminal_backend,
            "vte",
            "ghosttykit_renderer_unsupported_on_linux_backend",
            renderer=linux_terminal_renderer_capability(),
            scanner=linux_port_scanner_capability(),
            unsupported=[
                "ghosttykit_renderer",
                "ghosttykit_port_scanner",
            ],
        ),
        "packaging": status_payload(
            True,
            "linux_package_validator",
            "artifact",
            "tarball_deb_appimage_rpm_flatpak_validator_with_manifest_enabled",
            manifest="share/cmux/package-manifest.json",
            formats=packaging_formats(),
        ),
    }


def validate_subsystem_capabilities(capabilities: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    for subsystem in REQUIRED_SUBSYSTEMS:
        payload = capabilities.get(subsystem)
        if not isinstance(payload, dict):
            errors.append(f"missing subsystem: {subsystem}")
            continue
        for key in REQUIRED_STATUS_KEYS:
            if key not in payload:
                errors.append(f"{subsystem} missing {key}")
    return errors
