#!/usr/bin/env python3
"""
Regression tests for Resources/bin/open.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "open"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_log(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def run_wrapper(
    *,
    args: list[str],
    intercept_setting: str | None,
    browser_disabled_setting: str | None = None,
    external_application: str | None = None,
    legacy_open_setting: str | None = None,
    whitelist: str | None,
    external_patterns: str | None = None,
    fail_urls: list[str] | None = None,
    local_files: list[str] | None = None,
    python_bin: str | None = None,
    bash_bin: str = "/bin/bash",
    extra_env: dict[str, str | None] | None = None,
    locale_capture: dict[str, list[str]] | None = None,
) -> tuple[list[str], list[str], int, str]:
    """Run Resources/bin/open with faked system_open/cmux/defaults and return its dispatch.

    If `locale_capture` is given, it is populated (before the temp dir is
    cleaned up) with the LC_ALL each fake child process observed, under the
    keys "open" and "cmux" -- used to verify the wrapper restores the
    caller's original locale for dispatch instead of leaking its own
    internal `LC_ALL=C` (see test_child_processes_observe_original_locale).
    """
    with tempfile.TemporaryDirectory(prefix="cmux-open-wrapper-test-") as td:
        tmp = Path(td)
        wrapper = tmp / "open"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        open_log = tmp / "open.log"
        cmux_log = tmp / "cmux.log"
        open_locale_log = tmp / "open-locale.log"
        cmux_locale_log = tmp / "cmux-locale.log"
        system_open = tmp / "system-open"
        defaults = tmp / "defaults"
        cmux = tmp / "cmux"

        make_executable(
            system_open,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_OPEN_LOG"
printf '%s\\n' "${LC_ALL-<unset>}" >> "$FAKE_OPEN_LOCALE_LOG"
""",
        )

        make_executable(
            defaults,
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "read" ]]; then
  exit 1
fi
key="${3:-}"
case "$key" in
  browserInterceptTerminalOpenCommandInCmuxBrowser)
    if [[ "${FAKE_DEFAULTS_INTERCEPT_OPEN+x}" == "x" ]]; then
      printf '%s\\n' "$FAKE_DEFAULTS_INTERCEPT_OPEN"
      exit 0
    fi
    exit 1
    ;;
  browserDisabledOverride)
    if [[ "${FAKE_DEFAULTS_BROWSER_DISABLED+x}" == "x" ]]; then
      printf '%s\\n' "$FAKE_DEFAULTS_BROWSER_DISABLED"
      exit 0
    fi
    exit 1
    ;;
  browserExternalApplication)
    if [[ "${FAKE_DEFAULTS_EXTERNAL_APPLICATION+x}" == "x" ]]; then
      printf '%s\n' "$FAKE_DEFAULTS_EXTERNAL_APPLICATION"
      exit 0
    fi
    exit 1
    ;;
  browserOpenTerminalLinksInCmuxBrowser)
    if [[ "${FAKE_DEFAULTS_LEGACY_OPEN+x}" == "x" ]]; then
      printf '%s\\n' "$FAKE_DEFAULTS_LEGACY_OPEN"
      exit 0
    fi
    exit 1
    ;;
  browserHostWhitelist)
    if [[ "${FAKE_DEFAULTS_WHITELIST+x}" == "x" ]]; then
      printf '%s' "$FAKE_DEFAULTS_WHITELIST"
      exit 0
    fi
    exit 1
    ;;
  browserExternalOpenPatterns)
    if [[ "${FAKE_DEFAULTS_EXTERNAL_PATTERNS+x}" == "x" ]]; then
      printf '%s' "$FAKE_DEFAULTS_EXTERNAL_PATTERNS"
      exit 0
    fi
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
""",
        )

        make_executable(
            cmux,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_CMUX_LOG"
printf '%s\\n' "${LC_ALL-<unset>}" >> "$FAKE_CMUX_LOCALE_LOG"
url=""
for arg in "$@"; do
  url="$arg"
done
if [[ -n "${FAKE_CMUX_FAIL_URLS:-}" ]]; then
  IFS=',' read -r -a failures <<< "$FAKE_CMUX_FAIL_URLS"
  for fail_url in "${failures[@]}"; do
    if [[ "$url" == "$fail_url" ]]; then
      exit 1
    fi
  done
fi
exit 0
""",
        )

        if local_files:
            for relative_path in local_files:
                target = tmp / relative_path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("<!doctype html><title>fixture</title>", encoding="utf-8")

        env = os.environ.copy()
        env["CMUX_SOCKET_PATH"] = "/tmp/cmux-open-wrapper-test.sock"
        env["CMUX_BUNDLE_ID"] = "com.cmuxterm.app.debug.test"
        env["CMUX_OPEN_WRAPPER_SYSTEM_OPEN"] = str(system_open)
        env["CMUX_OPEN_WRAPPER_DEFAULTS"] = str(defaults)
        env["FAKE_OPEN_LOG"] = str(open_log)
        env["FAKE_CMUX_LOG"] = str(cmux_log)
        env["FAKE_OPEN_LOCALE_LOG"] = str(open_locale_log)
        env["FAKE_CMUX_LOCALE_LOG"] = str(cmux_locale_log)
        if python_bin is None:
            env.pop("CMUX_OPEN_WRAPPER_PYTHON3", None)
        else:
            env["CMUX_OPEN_WRAPPER_PYTHON3"] = python_bin

        if intercept_setting is None:
            env.pop("FAKE_DEFAULTS_INTERCEPT_OPEN", None)
        else:
            env["FAKE_DEFAULTS_INTERCEPT_OPEN"] = intercept_setting

        if browser_disabled_setting is None:
            env.pop("FAKE_DEFAULTS_BROWSER_DISABLED", None)
        else:
            env["FAKE_DEFAULTS_BROWSER_DISABLED"] = browser_disabled_setting

        if external_application is None:
            env.pop("FAKE_DEFAULTS_EXTERNAL_APPLICATION", None)
        else:
            env["FAKE_DEFAULTS_EXTERNAL_APPLICATION"] = external_application

        if legacy_open_setting is None:
            env.pop("FAKE_DEFAULTS_LEGACY_OPEN", None)
        else:
            env["FAKE_DEFAULTS_LEGACY_OPEN"] = legacy_open_setting

        if whitelist is None:
            env.pop("FAKE_DEFAULTS_WHITELIST", None)
        else:
            env["FAKE_DEFAULTS_WHITELIST"] = whitelist

        if external_patterns is None:
            env.pop("FAKE_DEFAULTS_EXTERNAL_PATTERNS", None)
        else:
            env["FAKE_DEFAULTS_EXTERNAL_PATTERNS"] = external_patterns

        if fail_urls:
            env["FAKE_CMUX_FAIL_URLS"] = ",".join(fail_urls)
        else:
            env.pop("FAKE_CMUX_FAIL_URLS", None)

        if extra_env:
            for key, value in extra_env.items():
                if value is None:
                    env.pop(key, None)
                else:
                    env[key] = value

        result = subprocess.run(
            [bash_bin, str(wrapper), *args],
            cwd=tmp,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

        if locale_capture is not None:
            locale_capture["open"] = read_log(open_locale_log)
            locale_capture["cmux"] = read_log(cmux_locale_log)

        return read_log(open_log), read_log(cmux_log), result.returncode, result.stderr.strip()


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def discover_alternate_bash_binaries() -> list[str]:
    """Find bash builds other than the default /bin/bash.

    Some third-party bash builds (observed with MacPorts bash 5.3.9 on
    macOS 15) crash with SIGSEGV in their multibyte-aware glob/pattern
    matcher when a case statement or ${var%pattern}/${var#pattern}
    expansion is evaluated against a non-ASCII argument under a UTF-8
    locale. /bin/bash (Apple's bundled bash 3.2) does not reproduce this,
    so this regression test only has teeth on a machine that also has one
    of these alternate builds installed.
    """
    candidates = [
        "/opt/local/bin/bash",
        "/usr/local/bin/bash",
        "/opt/homebrew/bin/bash",
    ]
    which_bash = shutil.which("bash")
    if which_bash and which_bash not in candidates:
        candidates.append(which_bash)

    found = []
    for candidate in candidates:
        path = Path(candidate)
        if path.is_file() and os.access(path, os.X_OK) and str(path) != "/bin/bash":
            found.append(str(path))
    return found


def test_toggle_disabled_passthrough(failures: list[str]) -> None:
    url = "https://example.com"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="0",
        whitelist="",
    )
    expect(code == 0, f"toggle off: wrapper exited {code}: {stderr}", failures)
    expect(cmux_log == [], f"toggle off: cmux should not be called, got {cmux_log}", failures)
    expect(open_log == [url], f"toggle off: expected system open [{url}], got {open_log}", failures)


def test_toggle_disabled_case_insensitive_passthrough(failures: list[str]) -> None:
    url = "https://example.com"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting=" FaLsE ",
        whitelist="",
    )
    expect(code == 0, f"toggle off (case-insensitive): wrapper exited {code}: {stderr}", failures)
    expect(
        cmux_log == [],
        f"toggle off (case-insensitive): cmux should not be called, got {cmux_log}",
        failures,
    )
    expect(
        open_log == [url],
        f"toggle off (case-insensitive): expected system open [{url}], got {open_log}",
        failures,
    )


def test_browser_disabled_override_passthrough(failures: list[str]) -> None:
    url = "https://example.com"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        browser_disabled_setting=" true ",
        whitelist="",
    )
    expect(code == 0, f"browser disabled override: wrapper exited {code}: {stderr}", failures)
    expect(cmux_log == [], f"browser disabled override: cmux should not be called, got {cmux_log}", failures)
    expect(
        open_log == [url],
        f"browser disabled override: expected one system open [{url}], got {open_log}",
        failures,
    )


def test_configured_external_application_is_used(failures: list[str]) -> None:
    url = "https://example.com"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        browser_disabled_setting="true",
        external_application="com.google.Chrome",
        whitelist="",
    )
    expect(code == 0, f"configured external application: wrapper exited {code}: {stderr}", failures)
    expect(cmux_log == [], f"configured external application: cmux should not be called, got {cmux_log}", failures)
    expect(
        open_log == [f"-a com.google.Chrome {url}"],
        f"configured external application: expected app-specific open, got {open_log}",
        failures,
    )


def test_whitelist_miss_passthrough(failures: list[str]) -> None:
    url = "https://example.com"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="localhost\n127.0.0.1",
    )
    expect(code == 0, f"whitelist miss: wrapper exited {code}: {stderr}", failures)
    expect(cmux_log == [], f"whitelist miss: cmux should not be called, got {cmux_log}", failures)
    expect(open_log == [url], f"whitelist miss: expected system open [{url}], got {open_log}", failures)


def test_whitelist_match_routes_to_cmux(failures: list[str]) -> None:
    url = "https://api.example.com/path?q=1"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="*.example.com",
    )
    expect(code == 0, f"whitelist match: wrapper exited {code}: {stderr}", failures)
    expect(open_log == [], f"whitelist match: system open should not be called, got {open_log}", failures)
    expect(cmux_log == [f"browser open {url}"], f"whitelist match: unexpected cmux log {cmux_log}", failures)


def test_external_literal_pattern_is_deferred_to_app(failures: list[str]) -> None:
    url = "https://platform.openai.com/account/usage"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="",
        external_patterns="platform.openai.com/account/usage",
    )
    expect(code == 0, f"external literal deferred: wrapper exited {code}: {stderr}", failures)
    expect(
        cmux_log == [f"browser open {url}"],
        f"external literal deferred: expected wrapper to pass URL to cmux, got {cmux_log}",
        failures,
    )
    expect(
        open_log == [],
        f"external literal deferred: system open should not be called by wrapper, got {open_log}",
        failures,
    )


def test_external_regex_pattern_is_deferred_to_app(failures: list[str]) -> None:
    url = "https://foo.example.com/billing"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="*.example.com",
        external_patterns=r"re:^https?://[^/]*\.example\.com/(billing|usage)",
    )
    expect(code == 0, f"external regex deferred: wrapper exited {code}: {stderr}", failures)
    expect(
        cmux_log == [f"browser open {url}"],
        f"external regex deferred: expected wrapper to pass URL to cmux, got {cmux_log}",
        failures,
    )
    expect(
        open_log == [],
        f"external regex deferred: system open should not be called by wrapper, got {open_log}",
        failures,
    )


def test_external_regex_with_icu_features_is_deferred_to_app(failures: list[str]) -> None:
    url = "https://example.com/usage/42"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="example.com",
        external_patterns=r"re:^https://example\.com/usage/\d+$",
    )
    expect(code == 0, f"external regex icu deferred: wrapper exited {code}: {stderr}", failures)
    expect(
        cmux_log == [f"browser open {url}"],
        f"external regex icu deferred: expected wrapper to pass URL to cmux, got {cmux_log}",
        failures,
    )
    expect(
        open_log == [],
        f"external regex icu deferred: system open should not be called by wrapper, got {open_log}",
        failures,
    )


def test_external_invalid_regex_is_ignored_silently(failures: list[str]) -> None:
    url = "https://example.com/path"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="",
        external_patterns=r"re:[unclosed",
    )
    expect(code == 0, f"external invalid regex: wrapper exited {code}: {stderr}", failures)
    expect(
        cmux_log == [f"browser open {url}"],
        f"external invalid regex: expected cmux open for {url}, got {cmux_log}",
        failures,
    )
    expect(
        open_log == [],
        f"external invalid regex: expected no system open calls, got {open_log}",
        failures,
    )
    expect(
        "invalid regular expression" not in stderr.lower(),
        f"external invalid regex: stderr should stay clean, got {stderr!r}",
        failures,
    )


def test_partial_failures_only_fallback_failed_urls(failures: list[str]) -> None:
    good = "https://api.example.com"
    failed = "https://fail.example.com"
    external = "https://outside.test"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[good, failed, external],
        intercept_setting="1",
        whitelist="*.example.com",
        fail_urls=[failed],
    )
    expect(code == 0, f"partial failure: wrapper exited {code}: {stderr}", failures)
    expect(
        cmux_log == [f"browser open {good}", f"browser open {failed}"],
        f"partial failure: cmux log mismatch {cmux_log}",
        failures,
    )
    expect(
        open_log == [f"{failed} {external}"],
        f"partial failure: expected fallback for failed/external only, got {open_log}",
        failures,
    )


def test_legacy_toggle_fallback_passthrough(failures: list[str]) -> None:
    url = "https://example.com"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting=None,
        legacy_open_setting="0",
        whitelist="",
    )
    expect(code == 0, f"legacy fallback: wrapper exited {code}: {stderr}", failures)
    expect(cmux_log == [], f"legacy fallback: cmux should not be called, got {cmux_log}", failures)
    expect(open_log == [url], f"legacy fallback: expected system open [{url}], got {open_log}", failures)


def test_legacy_toggle_fallback_case_insensitive_passthrough(failures: list[str]) -> None:
    url = "https://example.com"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting=None,
        legacy_open_setting=" Off ",
        whitelist="",
    )
    expect(code == 0, f"legacy fallback (case-insensitive): wrapper exited {code}: {stderr}", failures)
    expect(
        cmux_log == [],
        f"legacy fallback (case-insensitive): cmux should not be called, got {cmux_log}",
        failures,
    )
    expect(
        open_log == [url],
        f"legacy fallback (case-insensitive): expected system open [{url}], got {open_log}",
        failures,
    )


def test_uppercase_scheme_routes_to_cmux(failures: list[str]) -> None:
    url = "HTTPS://api.example.com/path?q=1"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="*.example.com",
    )
    expect(code == 0, f"uppercase scheme: wrapper exited {code}: {stderr}", failures)
    expect(open_log == [], f"uppercase scheme: system open should not be called, got {open_log}", failures)
    expect(cmux_log == [f"browser open {url}"], f"uppercase scheme: unexpected cmux log {cmux_log}", failures)


def test_local_html_file_routes_to_cmux(failures: list[str]) -> None:
    filename = "fixtures/hello page.HTML"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[filename],
        intercept_setting="1",
        whitelist="",
        local_files=[filename],
    )
    expect(code == 0, f"local html file: wrapper exited {code}: {stderr}", failures)
    expect(open_log == [], f"local html file: system open should not be called, got {open_log}", failures)
    expect(len(cmux_log) == 1, f"local html file: expected exactly one cmux call, got {cmux_log}", failures)
    if cmux_log:
        expect(
            cmux_log[0].startswith("browser open file://"),
            f"local html file: expected file:// target, got {cmux_log[0]}",
            failures,
        )
        expect(
            "hello%20page.HTML" in cmux_log[0],
            f"local html file: expected URL-encoded filename in cmux target, got {cmux_log[0]}",
            failures,
        )


def test_file_url_html_routes_to_cmux(failures: list[str]) -> None:
    url = "file:///tmp/cmux-open-wrapper-fixture.html"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="",
    )
    expect(code == 0, f"file url html: wrapper exited {code}: {stderr}", failures)
    expect(open_log == [], f"file url html: system open should not be called, got {open_log}", failures)
    expect(cmux_log == [f"browser open {url}"], f"file url html: unexpected cmux log {cmux_log}", failures)


def test_file_url_html_routes_to_cmux_without_python_binary(failures: list[str]) -> None:
    url = "file:///tmp/cmux-open-wrapper-fixture.html"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="",
        python_bin="/definitely/missing/python3",
    )
    expect(code == 0, f"file url html no-python fallback: wrapper exited {code}: {stderr}", failures)
    expect(
        open_log == [],
        f"file url html no-python fallback: system open should not be called, got {open_log}",
        failures,
    )
    expect(
        cmux_log == [f"browser open {url}"],
        f"file url html no-python fallback: unexpected cmux log {cmux_log}",
        failures,
    )


def test_local_html_file_routes_to_cmux_without_python_binary(failures: list[str]) -> None:
    filename = "fixtures/no python fallback.html"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[filename],
        intercept_setting="1",
        whitelist="",
        local_files=[filename],
        python_bin="/definitely/missing/python3",
    )
    expect(code == 0, f"local html no-python fallback: wrapper exited {code}: {stderr}", failures)
    expect(open_log == [], f"local html no-python fallback: system open should not be called, got {open_log}", failures)
    expect(
        len(cmux_log) == 1,
        f"local html no-python fallback: expected exactly one cmux call, got {cmux_log}",
        failures,
    )
    if cmux_log:
        expect(
            cmux_log[0].startswith("browser open file://"),
            f"local html no-python fallback: expected file:// target, got {cmux_log[0]}",
            failures,
        )
        expect(
            "no%20python%20fallback.html" in cmux_log[0],
            f"local html no-python fallback: expected URL-encoded filename, got {cmux_log[0]}",
            failures,
        )


def test_domain_like_html_argument_passthrough(failures: list[str]) -> None:
    arg = "example.com/report.html"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[arg],
        intercept_setting="1",
        whitelist="",
    )
    expect(code == 0, f"domain-like html argument: wrapper exited {code}: {stderr}", failures)
    expect(
        cmux_log == [],
        f"domain-like html argument: cmux should not be called, got {cmux_log}",
        failures,
    )
    expect(
        open_log == [arg],
        f"domain-like html argument: expected system open [{arg}], got {open_log}",
        failures,
    )


def test_non_file_scheme_html_passthrough(failures: list[str]) -> None:
    url = "ftp://example.com/report.html"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="",
    )
    expect(code == 0, f"non-file scheme html: wrapper exited {code}: {stderr}", failures)
    expect(cmux_log == [], f"non-file scheme html: cmux should not be called, got {cmux_log}", failures)
    expect(open_log == [url], f"non-file scheme html: expected system open [{url}], got {open_log}", failures)


def test_mailto_html_passthrough(failures: list[str]) -> None:
    url = "mailto:help@example.com?subject=report.html"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="",
    )
    expect(code == 0, f"mailto html: wrapper exited {code}: {stderr}", failures)
    expect(cmux_log == [], f"mailto html: cmux should not be called, got {cmux_log}", failures)
    expect(open_log == [url], f"mailto html: expected system open [{url}], got {open_log}", failures)


def test_local_non_html_file_passthrough(failures: list[str]) -> None:
    filename = "fixtures/readme.md"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[filename],
        intercept_setting="1",
        whitelist="",
        local_files=[filename],
    )
    expect(code == 0, f"local non-html file: wrapper exited {code}: {stderr}", failures)
    expect(cmux_log == [], f"local non-html file: cmux should not be called, got {cmux_log}", failures)
    expect(open_log == [filename], f"local non-html file: expected system open [{filename}], got {open_log}", failures)


def _run_multibyte_argument(bash_bin: str) -> tuple[list[str], list[str], int, str]:
    """Run the wrapper on a Japanese filename argument under a UTF-8 locale."""
    filename = "日本語.pdf"
    return run_wrapper(
        args=[filename],
        intercept_setting="1",
        whitelist="",
        local_files=[filename],
        bash_bin=bash_bin,
        extra_env={
            "LANG": "ja_JP.UTF-8",
            "LC_CTYPE": "ja_JP.UTF-8",
            "LC_ALL": "",
        },
    )


def test_multibyte_filename_argument_does_not_crash_default_bash(failures: list[str]) -> None:
    """Sanity baseline: a multibyte filename passes through unchanged on /bin/bash."""
    filename = "日本語.pdf"
    open_log, cmux_log, code, stderr = _run_multibyte_argument("/bin/bash")
    expect(
        code == 0,
        f"multibyte filename (/bin/bash): wrapper exited {code}: {stderr}",
        failures,
    )
    expect(
        cmux_log == [],
        f"multibyte filename (/bin/bash): cmux should not be called, got {cmux_log}",
        failures,
    )
    expect(
        open_log == [filename],
        f"multibyte filename (/bin/bash): expected system open [{filename}], got {open_log}",
        failures,
    )


def test_multibyte_filename_argument_does_not_crash_alternate_bash_builds(
    failures: list[str],
) -> None:
    """Regression test for the trim()/case-statement multibyte SIGSEGV.

    Some bash builds crash in their multibyte-aware glob/pattern matcher
    when a case statement or pattern-removal expansion runs against a
    non-ASCII argument (e.g. a Japanese filename) under a UTF-8 locale.
    This only reproduces on a bash build with that bug, so it is a no-op
    (documented, not failed) when none is installed on the machine running
    this test.
    """
    alternates = discover_alternate_bash_binaries()
    if not alternates:
        print(
            "note: no alternate bash build found (e.g. MacPorts /opt/local/bin/bash); "
            "skipping multibyte-argument crash repro (see cmux issue for the original "
            "SIGSEGV report under MacPorts bash 5.3.9)."
        )
        return

    filename = "日本語.pdf"
    for bash_bin in alternates:
        open_log, cmux_log, code, stderr = _run_multibyte_argument(bash_bin)
        expect(
            code != -11 and code != 139,
            f"multibyte filename ({bash_bin}): wrapper crashed with SIGSEGV "
            f"(exit {code}): {stderr}",
            failures,
        )
        expect(
            code == 0,
            f"multibyte filename ({bash_bin}): wrapper exited {code}: {stderr}",
            failures,
        )
        expect(
            cmux_log == [],
            f"multibyte filename ({bash_bin}): cmux should not be called, got {cmux_log}",
            failures,
        )
        expect(
            open_log == [filename],
            f"multibyte filename ({bash_bin}): expected system open [{filename}], got {open_log}",
            failures,
        )


_HEREDOC_OPEN_RE = re.compile(r"<<-?\s*'?([A-Za-z_][A-Za-z0-9_]*)'?")
_TRAILING_COMMENT_RE = re.compile(r"(?:^|\s)#.*$")
_CASE_RE = re.compile(r"(?:^|[;&|]\s*)case\b")
_PATTERN_REMOVAL_RE = re.compile(r"\$\{(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+)(\[[^]]*\])?(##?|%%?)")


def _strip_trailing_comment(line: str) -> str:
    """Best-effort strip of a ' #...' trailing comment for heuristic matching.

    Does not track quotes, so a literal '#' preceded by whitespace inside a
    quoted string would be misread as a comment start. No top-level line in
    this script does that today.
    """
    match = _TRAILING_COMMENT_RE.search(line)
    return line[: match.start()] if match else line


def _top_level_statement_lines(lines: list[str]) -> list[tuple[int, str]]:
    """Return (0-based index, text) for lines bash runs unconditionally at load.

    Excludes function-body lines (indented in this file, and only executed
    once the function is *called* -- every function here is called after the
    locale fix) and heredoc bodies (verbatim text, never parsed as bash
    statements). A heredoc operator is only recognized outside a trailing
    comment, so e.g. `x=1  # example: <<EOF` does not start heredoc tracking.

    Does not attempt to special-case indented top-level if/for/while bodies
    (as opposed to function bodies) -- this script has none that touch
    arguments, and distinguishing those in general needs real bash parsing,
    out of scope for this guard. Nor does it track quoting, so a heredoc-like
    `<<NAME` inside a quoted string (e.g. `echo "use <<EOF here"`) would still
    be misdetected as a real heredoc open; no such line exists in this script
    today.
    """
    result = []
    heredoc_terminator: str | None = None
    for i, line in enumerate(lines):
        if heredoc_terminator is not None:
            if line == heredoc_terminator:
                heredoc_terminator = None
            continue
        if line and line[0] not in (" ", "\t") and not line.startswith("#"):
            result.append((i, line))
        heredoc_open = _HEREDOC_OPEN_RE.search(_strip_trailing_comment(line))
        if heredoc_open:
            heredoc_terminator = heredoc_open.group(1)
    return result


def test_top_level_statement_line_heuristics(failures: list[str]) -> None:
    """Pin the exact behavior of the _top_level_statement_lines heuristic.

    Regression inputs requested in review: a commented-out heredoc-looking
    line must not start heredoc tracking; a top-level `case` after a `;`
    separator must still be detected; a heredoc-like token inside a quoted
    string is a known, documented false positive (no such line exists in
    Resources/bin/open today).
    """
    synthetic = [
        'before_comment_heredoc="x"',
        'x=1  # example: <<EOF style heredoc, not a real one',
        'after_comment_heredoc="y"',
        "func_with_real_heredoc() {",
        "    value=\"$(cmd <<'PY'",
        "heredoc body line that must be skipped, not a top-level statement",
        "PY",
        ")\"",
        "}",
        'after_real_heredoc="z"',
        'true; case "$x" in',
        "esac",
    ]
    top_level_texts = [line for _, line in _top_level_statement_lines(synthetic)]

    expect(
        "after_comment_heredoc=\"y\"" in top_level_texts,
        "a '#' comment mentioning '<<EOF' must not start heredoc tracking "
        f"and swallow the next top-level statement, got {top_level_texts!r}",
        failures,
    )
    expect(
        "heredoc body line that must be skipped, not a top-level statement"
        not in top_level_texts,
        "a real heredoc body must not be treated as a top-level statement",
        failures,
    )
    expect(
        'after_real_heredoc="z"' in top_level_texts,
        "the statement following a real heredoc's closing delimiter must "
        f"still be seen as top-level, got {top_level_texts!r}",
        failures,
    )
    expect(
        any(_CASE_RE.search(_strip_trailing_comment(t)) for t in top_level_texts if t == 'true; case "$x" in'),
        "a top-level 'case' appearing after a ';' separator must be detected",
        failures,
    )
    for separator, sample in (
        ("&&", 'true && case "$x" in'),
        ("||", 'false || case "$x" in'),
    ):
        expect(
            bool(_CASE_RE.search(_strip_trailing_comment(sample))),
            f"a top-level 'case' appearing after a '{separator}' separator must be detected, got {sample!r}",
            failures,
        )

    # Known, documented limitation: no quote-tracking, so a heredoc-like
    # token inside a quoted string is misdetected as a real heredoc open.
    # This pins that documented behavior rather than silently drifting.
    quoted_lookalike = ['echo "use <<EOF here"', "should_be_swallowed=1"]
    quoted_top_level = [line for _, line in _top_level_statement_lines(quoted_lookalike)]
    expect(
        "should_be_swallowed=1" not in quoted_top_level,
        "documented limitation regressed: a quoted heredoc-like token no "
        "longer starts (false-positive) heredoc tracking -- if this now "
        "fails, the limitation note on _top_level_statement_lines is stale "
        "and should be updated",
        failures,
    )


def test_pattern_removal_regex_detects_positional_parameters(failures: list[str]) -> None:
    """_PATTERN_REMOVAL_RE must catch pattern removal on $1, $2, ... too.

    Resources/bin/open always copies an argument into a named local (e.g.
    `local value="$1"`) before trimming it, so today only named-variable
    pattern removal appears before LC_ALL=C. But an attacker-controlled
    wrapper argument reaches bash as a positional parameter first, and
    `${1#prefix}`/`${1%suffix}` crash the same way as the named-variable
    form on the affected bash builds -- so the guard must not have a blind
    spot for someone pattern-matching a positional parameter directly.
    """
    positional_cases = ['${1#prefix}', '${1%suffix}', '${1##prefix}', '${1%%suffix}', '${10#prefix}']
    for sample in positional_cases:
        expect(
            bool(_PATTERN_REMOVAL_RE.search(sample)),
            f"expected _PATTERN_REMOVAL_RE to match positional-parameter pattern removal {sample!r}",
            failures,
        )

    # Preserve existing named-variable matching (this is not a replacement).
    expect(
        bool(_PATTERN_REMOVAL_RE.search("${value#pattern}")),
        "named-variable pattern removal must still match after adding positional-parameter support",
        failures,
    )

    # End-to-end: the same case/pattern-removal scan used by
    # test_wrapper_forces_c_locale_before_arg_processing must flag a
    # positional-parameter pattern removal that runs on an
    # attacker-controlled argument before LC_ALL=C is set.
    vulnerable_script = [
        'value="$1"',
        'trimmed="${1#prefix}"',
        "export LC_ALL=C",
    ]
    top_level = _top_level_statement_lines(vulnerable_script)
    lc_all_index = next(i for i, line in top_level if line == "export LC_ALL=C")
    flagged = [
        line
        for i, line in top_level
        if i < lc_all_index and _PATTERN_REMOVAL_RE.search(_strip_trailing_comment(line))
    ]
    expect(
        flagged == ['trimmed="${1#prefix}"'],
        "expected the positional-parameter pattern removal ahead of 'export "
        f"LC_ALL=C' to be flagged, got {flagged!r}",
        failures,
    )


def test_wrapper_forces_c_locale_before_arg_processing(failures: list[str]) -> None:
    """Static guard for the multibyte SIGSEGV fix.

    CI does not provision a bash build affected by the crash (see
    test_multibyte_filename_argument_does_not_crash_alternate_bash_builds,
    which is a no-op there), so a dynamic repro alone would not catch someone
    later dropping the mitigation, or reintroducing a `case` statement or
    `${var%pattern}`/`${var#pattern}` expansion -- the two constructs that
    crash on the affected bash builds -- ahead of the fix. This checks the
    fix statically instead: `export LC_ALL=C` must be present, and no
    top-level statement before it may contain either construct.
    """
    source = SOURCE_WRAPPER.read_text(encoding="utf-8")
    lines = source.splitlines()
    top_level = _top_level_statement_lines(lines)

    lc_all_index = next(
        (i for i, line in top_level if re.match(r"^export LC_ALL=C\s*$", line)),
        None,
    )
    expect(
        lc_all_index is not None,
        "expected 'export LC_ALL=C' in Resources/bin/open to force byte-wise "
        "glob/pattern matching (see the multibyte SIGSEGV fix)",
        failures,
    )
    if lc_all_index is None:
        return

    for i, line in top_level:
        if i >= lc_all_index:
            break
        code = _strip_trailing_comment(line)
        if _CASE_RE.search(code) or _PATTERN_REMOVAL_RE.search(code):
            failures.append(
                f"Resources/bin/open:{i + 1}: top-level case/pattern-removal "
                f"construct appears before 'export LC_ALL=C': {line!r}"
            )

    arg_scan_index = next(
        (i for i, line in top_level if line.startswith('for arg in "$@"; do')),
        None,
    )
    expect(
        arg_scan_index is not None,
        "expected the wrapper's arg-scanning loop ('for arg in \"$@\"; do') to still exist",
        failures,
    )
    if arg_scan_index is None:
        return

    expect(
        lc_all_index < arg_scan_index,
        "'export LC_ALL=C' must be set before the wrapper starts case/pattern "
        "matching against arguments, or the multibyte SIGSEGV fix has no effect",
        failures,
    )


def test_system_open_observes_original_locale(failures: list[str]) -> None:
    """system_open must restore the caller's locale, not leak LC_ALL=C.

    `export LC_ALL=C` forces byte-wise matching for this script's own bash
    pattern matching (see test_wrapper_forces_c_locale_before_arg_processing),
    but /usr/bin/open should still see whatever locale the caller actually
    had -- forcing C for it too would be an unintended side effect on real
    locale-sensitive behavior in the system `open` command.
    """
    filename = "readme.txt"

    # Case 1: caller had a real, non-C locale set.
    locale_capture: dict[str, list[str]] = {}
    run_wrapper(
        args=[filename],
        intercept_setting="1",
        whitelist="",
        local_files=[filename],
        locale_capture=locale_capture,
        extra_env={"LC_ALL": "ja_JP.UTF-8"},
    )
    expect(
        locale_capture.get("open") == ["ja_JP.UTF-8"],
        "system_open should observe the caller's original LC_ALL "
        f"('ja_JP.UTF-8'), not the wrapper's internal C locale, got {locale_capture.get('open')!r}",
        failures,
    )

    # Case 2: caller had no LC_ALL set at all -- system_open must not inherit
    # the wrapper's forced C either; it should see LC_ALL unset too.
    locale_capture_unset: dict[str, list[str]] = {}
    run_wrapper(
        args=[filename],
        intercept_setting="1",
        whitelist="",
        local_files=[filename],
        locale_capture=locale_capture_unset,
        extra_env={"LC_ALL": None},
    )
    expect(
        locale_capture_unset.get("open") == ["<unset>"],
        "system_open should observe LC_ALL as unset when the caller never "
        f"set it, got {locale_capture_unset.get('open')!r}",
        failures,
    )


def test_cmux_cli_observes_original_locale(failures: list[str]) -> None:
    """The cmux CLI invocation must also restore the caller's original locale."""
    url = "https://example.com"

    locale_capture: dict[str, list[str]] = {}
    run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="*.example.com",
        locale_capture=locale_capture,
        extra_env={"LC_ALL": "de_DE.UTF-8"},
    )
    expect(
        locale_capture.get("cmux") == ["de_DE.UTF-8"],
        "the cmux CLI should observe the caller's original LC_ALL "
        f"('de_DE.UTF-8'), not the wrapper's internal C locale, got {locale_capture.get('cmux')!r}",
        failures,
    )

    locale_capture_unset: dict[str, list[str]] = {}
    run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="*.example.com",
        locale_capture=locale_capture_unset,
        extra_env={"LC_ALL": None},
    )
    expect(
        locale_capture_unset.get("cmux") == ["<unset>"],
        "the cmux CLI should observe LC_ALL as unset when the caller never "
        f"set it, got {locale_capture_unset.get('cmux')!r}",
        failures,
    )


def test_unicode_whitelist_matches_punycode_url(failures: list[str]) -> None:
    url = "https://xn--bcher-kva.example/path"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="bücher.example",
    )
    expect(code == 0, f"unicode whitelist: wrapper exited {code}: {stderr}", failures)
    expect(open_log == [], f"unicode whitelist: system open should not be called, got {open_log}", failures)
    expect(cmux_log == [f"browser open {url}"], f"unicode whitelist: unexpected cmux log {cmux_log}", failures)


def test_punycode_whitelist_matches_unicode_url(failures: list[str]) -> None:
    url = "https://bücher.example/path"
    open_log, cmux_log, code, stderr = run_wrapper(
        args=[url],
        intercept_setting="1",
        whitelist="xn--bcher-kva.example",
    )
    expect(code == 0, f"punycode whitelist: wrapper exited {code}: {stderr}", failures)
    expect(open_log == [], f"punycode whitelist: system open should not be called, got {open_log}", failures)
    expect(cmux_log == [f"browser open {url}"], f"punycode whitelist: unexpected cmux log {cmux_log}", failures)


def main() -> int:
    """Run every open-wrapper regression test and report aggregate pass/fail."""
    failures: list[str] = []
    test_toggle_disabled_passthrough(failures)
    test_toggle_disabled_case_insensitive_passthrough(failures)
    test_browser_disabled_override_passthrough(failures)
    test_configured_external_application_is_used(failures)
    test_whitelist_miss_passthrough(failures)
    test_whitelist_match_routes_to_cmux(failures)
    test_external_literal_pattern_is_deferred_to_app(failures)
    test_external_regex_pattern_is_deferred_to_app(failures)
    test_external_regex_with_icu_features_is_deferred_to_app(failures)
    test_external_invalid_regex_is_ignored_silently(failures)
    test_partial_failures_only_fallback_failed_urls(failures)
    test_legacy_toggle_fallback_passthrough(failures)
    test_legacy_toggle_fallback_case_insensitive_passthrough(failures)
    test_uppercase_scheme_routes_to_cmux(failures)
    test_local_html_file_routes_to_cmux(failures)
    test_file_url_html_routes_to_cmux(failures)
    test_file_url_html_routes_to_cmux_without_python_binary(failures)
    test_local_html_file_routes_to_cmux_without_python_binary(failures)
    test_domain_like_html_argument_passthrough(failures)
    test_non_file_scheme_html_passthrough(failures)
    test_mailto_html_passthrough(failures)
    test_local_non_html_file_passthrough(failures)
    test_multibyte_filename_argument_does_not_crash_default_bash(failures)
    test_multibyte_filename_argument_does_not_crash_alternate_bash_builds(failures)
    test_top_level_statement_line_heuristics(failures)
    test_pattern_removal_regex_detects_positional_parameters(failures)
    test_wrapper_forces_c_locale_before_arg_processing(failures)
    test_system_open_observes_original_locale(failures)
    test_cmux_cli_observes_original_locale(failures)
    test_unicode_whitelist_matches_punycode_url(failures)
    test_punycode_whitelist_matches_unicode_url(failures)

    if failures:
        print("open wrapper regression tests failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("open wrapper regression tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
