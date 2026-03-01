#!/usr/bin/env python3
"""
Regression tests for Resources/bin/open.
"""

from __future__ import annotations

import os
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
    legacy_open_setting: str | None = None,
    whitelist: str | None,
    fail_urls: list[str] | None = None,
    local_files: list[str] | None = None,
    python_bin: str | None = None,
) -> tuple[list[str], list[str], int, str]:
    with tempfile.TemporaryDirectory(prefix="cmux-open-wrapper-test-") as td:
        tmp = Path(td)
        wrapper = tmp / "open"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        open_log = tmp / "open.log"
        cmux_log = tmp / "cmux.log"
        system_open = tmp / "system-open"
        defaults = tmp / "defaults"
        cmux = tmp / "cmux"

        make_executable(
            system_open,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_OPEN_LOG"
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
        if python_bin is None:
            env.pop("CMUX_OPEN_WRAPPER_PYTHON3", None)
        else:
            env["CMUX_OPEN_WRAPPER_PYTHON3"] = python_bin

        if intercept_setting is None:
            env.pop("FAKE_DEFAULTS_INTERCEPT_OPEN", None)
        else:
            env["FAKE_DEFAULTS_INTERCEPT_OPEN"] = intercept_setting

        if legacy_open_setting is None:
            env.pop("FAKE_DEFAULTS_LEGACY_OPEN", None)
        else:
            env["FAKE_DEFAULTS_LEGACY_OPEN"] = legacy_open_setting

        if whitelist is None:
            env.pop("FAKE_DEFAULTS_WHITELIST", None)
        else:
            env["FAKE_DEFAULTS_WHITELIST"] = whitelist

        if fail_urls:
            env["FAKE_CMUX_FAIL_URLS"] = ",".join(fail_urls)
        else:
            env.pop("FAKE_CMUX_FAIL_URLS", None)

        result = subprocess.run(
            ["/bin/bash", str(wrapper), *args],
            cwd=tmp,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

        return read_log(open_log), read_log(cmux_log), result.returncode, result.stderr.strip()


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


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
    failures: list[str] = []
    test_toggle_disabled_passthrough(failures)
    test_toggle_disabled_case_insensitive_passthrough(failures)
    test_whitelist_miss_passthrough(failures)
    test_whitelist_match_routes_to_cmux(failures)
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
