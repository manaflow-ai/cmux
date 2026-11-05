import { describe, expect, test } from "bun:test";
import { BROWSER_ROLE, chromeSandboxCommand, firstUseInstallPhases, hostSessionCommand, installProblems, userNamespaceCheckCommand } from "../scripts/cmux-vm-image/browser-probe";
import { readInputsLock, rolesManifest } from "../scripts/cmux-vm-image/lock";

const manifest = rolesManifest(readInputsLock());
const entry = manifest.roles[BROWSER_ROLE];

describe("browser role probe (cloud-automation.md 31)", () => {
  test("the first-use install reads only the dated snapshot, pins the exact closure, then fetches each first-use program", () => {
    const phases = firstUseInstallPhases(manifest, BROWSER_ROLE);
    expect(phases.map((p) => p.name)).toEqual(["apt-install", "program-chrome-for-testing", "program-cmux-browser-host"]);
    const cmd = phases.map((p) => p.command).join("\n");
    expect(cmd).toContain("-o Dir::Etc::sourcelist=/var/lib/cmux/apt-snapshot/snapshot.sources");
    expect(cmd).toContain("-o Dir::State::Lists=/var/lib/cmux/apt-snapshot/lists");
    expect(cmd).not.toContain("/etc/apt/sources.list.d");
    for (const [name, version] of Object.entries(manifest.firstUse[BROWSER_ROLE])) expect(cmd).toContain(`'${name}=${version}'`);
    expect(cmd).toContain(Buffer.from(manifest.aptSources).toString("base64"));
  });

  test("the install must add exactly the locked closure", () => {
    const closure = manifest.firstUse[BROWSER_ROLE];
    const exact = Object.entries(closure).map(([n, v]) => `ADDED\t${n}\t${v}`).join("\n");
    expect(installProblems(manifest, BROWSER_ROLE, exact)).toEqual([]);
    expect(installProblems(manifest, BROWSER_ROLE, `${exact}\nADDED\tgnome-shell\t46.0`).join(" ")).toContain("gnome-shell");
    const [first] = Object.keys(closure);
    expect(installProblems(manifest, BROWSER_ROLE, exact.replace(`ADDED\t${first}\t${closure[first]}`, "")).join(" ")).toContain(first);
  });

  test("Chrome runs with the role env, never a sandbox-off switch, and the probe reads the renderer's namespace and seccomp", () => {
    const cmd = chromeSandboxCommand(entry);
    const launches = cmd.split("\n").filter((line) => line.includes("--headless"));
    expect(launches.length).toBe(1);
    for (const line of launches) expect(line).not.toMatch(/--no-sandbox|--disable-setuid-sandbox/);
    expect(cmd).toContain("CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE='0'");
    expect(cmd).toContain(`CMUX_BROWSER_HOST_CHROMIUM='${entry.env.CMUX_BROWSER_HOST_CHROMIUM}'`);
    expect(cmd).toContain("/ns/user");
    expect(cmd).toContain("Seccomp:");
  });

  test("the user-namespace check runs as the work user and reports the kernel switches", () => {
    const cmd = userNamespaceCheckCommand();
    expect(cmd).toContain("unshare --user --map-root-user");
    expect(cmd).toContain("apparmor_restrict_unprivileged_userns");
  });

  test("the host smoke opens a loopback http page (the host refuses data: URLs), never pipes Chrome output through $(...), and measures the whole host session", () => {
    const cmd = hostSessionCommand(entry, 60);
    expect(cmd).toContain("http.server 18731 --bind 127.0.0.1");
    expect(cmd).toContain('page.goto(\"http://127.0.0.1:18731/\")'.replace(/\\/g, ""));
    expect(cmd).not.toContain("data:");
    expect(cmd).toContain('>"$d/eval.out"');
    expect(cmd).not.toContain("PIPESTATUS");
    expect(cmd).toContain("CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE='0'");
    expect(cmd).toContain("sleep 60; b=$(ticks)");
    for (const line of cmd.split("\n")) expect(line).not.toMatch(/--no-sandbox|--disable-setuid-sandbox/);
  });
});
