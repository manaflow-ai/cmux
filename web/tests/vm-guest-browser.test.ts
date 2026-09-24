import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GUEST_BROWSER_ENV, GUEST_BROWSER_FISH_ENV, GUEST_BROWSER_OPENER, GUEST_OS_BROWSER_WRAPPER } from "../services/vms/guestBrowser";

const terminal = "term_0123456789abcdef0123456789abcdef";
const url = "HTTPS://github.com/login/device?state=AbC%2B%2f&literal=$(dont-run)#fragment";

function fixture(body: (directory: string, env: NodeJS.ProcessEnv) => void) {
  const directory = mkdtempSync(join(tmpdir(), "guest-browser-"));
  try {
    writeFileSync(join(directory, "cmux-open-url"), GUEST_BROWSER_OPENER);
    chmodSync(join(directory, "cmux-open-url"), 0o755);
    // A deterministic daemon double validates the real low-level CLI grammar,
    // records exact JSON, and reports whether the frontend acknowledged delivery.
    writeFileSync(join(directory, "daemon"), `#!/bin/sh
[ "$1" = --session ] && [ "$2" = cloud ] && [ "$3" = --json ] && [ "$4" = raw ] && [ "$5" = command ] && [ "$6" = --request-json ] || exit 91
printf '%s' "$7" > "$HOME/request.json"
[ "$MODE" != broken ] || exit 3
printf '{"opened":%s}' "$MODE"
`);
    chmodSync(join(directory, "daemon"), 0o755);
    // macOS lacks timeout; a no-delay double preserves argv for these unit
    // cases. A real Linux daemon test covers the bounded wait separately.
    writeFileSync(join(directory, "timeout"), '#!/bin/sh\nshift\nexec "$@"\n');
    chmodSync(join(directory, "timeout"), 0o755);
    body(directory, { NODE_ENV: "test", PATH: `${directory}:${process.env.PATH}`, HOME: directory, CMUX_TUI_BIN: join(directory, "daemon"), CMUX_TUI_TERMINAL_ID: terminal, LANG: "en_US.UTF-8", MODE: "true", DISPLAY: ":1" });
  } finally { rmSync(directory, { recursive: true, force: true }); }
}

describe("guest OS browser opener", () => {
  test("forwards exact URL bytes and terminal identity only after host acknowledgement", () => fixture((directory, env) => {
    const result = spawnSync(join(directory, "cmux-open-url"), [url], { env, encoding: "utf8" });
    expect(result.status).toBe(0);
    expect(result.stdout).toBe("");
    expect(JSON.parse(readFileSync(join(directory, "request.json"), "utf8"))).toEqual({ cmd: "url-open", terminal_id: terminal, url });
  }));

  test.each(["false", "broken", "missing-terminal", "missing-daemon"])("returns a usable fallback on %s and lets callers continue polling", (mode) => fixture((directory, env) => {
    if (mode === "missing-terminal") delete env.CMUX_TUI_TERMINAL_ID;
    if (mode === "missing-daemon") env.CMUX_TUI_BIN = join(directory, "absent");
    env.MODE = mode;
    const result = spawnSync(join(directory, "cmux-open-url"), [url], { env, encoding: "utf8" });
    expect(result.status).toBe(0);
    expect(result.stdout).toBe(`Open this URL: ${url}\n`);
    expect(result.stderr).toBe("");
  }));

  test.each(["file:///tmp/secret", "javascript:alert(1)", "https://", "https://host/\ncommand"])("rejects invalid/non-web URL %s", (invalid) => fixture((directory, env) => {
    const result = spawnSync(join(directory, "cmux-open-url"), [invalid], { env, encoding: "utf8" });
    expect(result.status).toBe(2);
  }));

  test("localizes fallback without touching the URL", () => fixture((directory, env) => {
    env.LC_ALL = "ja_JP.UTF-8";
    env.MODE = "false";
    const result = spawnSync(join(directory, "cmux-open-url"), [url], { env, encoding: "utf8" });
    expect(result.stdout).toBe(`この URL を開いてください: ${url}\n`);
  }));

  test.each(["xdg-open", "x-www-browser", "sensible-browser"])("%s routes HTTP and preserves distro file/options behavior", (name) => fixture((directory, env) => {
    const wrapper = join(directory, name);
    const distro = join(directory, "distro");
    writeFileSync(wrapper, GUEST_OS_BROWSER_WRAPPER.replaceAll("/usr/local/bin/cmux-open-url", join(directory, "cmux-open-url")).replace('"/usr/bin/$name"', `"${distro}"`));
    chmodSync(wrapper, 0o755);
    writeFileSync(distro, '#!/bin/sh\nprintf "%s\\n" "$@"\n');
    chmodSync(distro, 0o755);
    expect(spawnSync(wrapper, [url], { env, encoding: "utf8" }).status).toBe(0);
    expect(JSON.parse(readFileSync(join(directory, "request.json"), "utf8"))).toEqual({ cmd: "url-open", terminal_id: terminal, url });
    expect(spawnSync(wrapper, ["/tmp/a b.pdf"], { env, encoding: "utf8" }).stdout).toBe("/tmp/a b.pdf\n");
    expect(spawnSync(wrapper, ["--help"], { env, encoding: "utf8" }).stdout).toBe("--help\n");
  }));

  test.each(["sh", "bash", "zsh"])("%s exports defaults, honors overrides, and preserves guest automation", (shell) => fixture((directory, env) => {
    const script = GUEST_BROWSER_ENV.replaceAll("/usr/local/bin/cmux-open-url", join(directory, "cmux-open-url"))
      + '\nprintf "%s\\n" "$BROWSER" "$GH_BROWSER" "$DISPLAY" "$AGENT_BROWSER_EXECUTABLE_PATH"';
    env.AGENT_BROWSER_EXECUTABLE_PATH = "/usr/bin/google-chrome-stable";
    const available = spawnSync("which", [shell], { env, encoding: "utf8" });
    if (available.status !== 0) return; // All shell families run in the Linux integration fixture.
    let result = spawnSync(shell, ["-c", script], { env, encoding: "utf8" });
    expect(result.status).toBe(0);
    expect(result.stdout.split("\n").slice(0, 4)).toEqual([join(directory, "cmux-open-url"), join(directory, "cmux-open-url"), ":1", "/usr/bin/google-chrome-stable"]);
    result = spawnSync(shell, ["-c", script], { env: { ...env, BROWSER: "/custom/browser" }, encoding: "utf8" });
    expect(result.stdout.split("\n").slice(0, 2)).toEqual(["/custom/browser", "/custom/browser"]);
  }));

  test("fish script preserves its native syntax", () => fixture((directory, env) => {
    const available = spawnSync("which", ["fish"], { env, encoding: "utf8" });
    if (available.status !== 0) return;
    const script = GUEST_BROWSER_FISH_ENV.replaceAll("/usr/local/bin/cmux-open-url", join(directory, "cmux-open-url")) + '\nprintf "%s\\n" $BROWSER $GH_BROWSER $DISPLAY';
    const result = spawnSync("fish", ["-c", script], { env, encoding: "utf8" });
    expect(result.stdout.split("\n").slice(0, 3)).toEqual([join(directory, "cmux-open-url"), join(directory, "cmux-open-url"), ":1"]);
  }));
});
