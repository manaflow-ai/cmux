// Hook/git harness, not full-app CPU. Run each arm in a fresh process on the same fleet worker:
// bun bench/diff-freshness-idle.bench.tsx [../src/diff-viewer/freshness.ts] [durationMs=60000]
// For the baseline, git show BASE:webviews/src/diff-viewer/freshness.ts > src/diff-viewer/freshness.before.ts
import { createHash } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { JSDOM, VirtualConsole } from "jsdom";
import { spawn } from "bun";

const moduleURL = new URL(
  process.argv[2] ?? process.env.FRESHNESS_MODULE ?? "../src/diff-viewer/freshness.ts",
  import.meta.url,
);
const durationMs = Number(process.argv[3] ?? process.env.DURATION_MS ?? 60_000);
if (!Number.isFinite(durationMs) || durationMs <= 0) throw new Error("durationMs must be positive");
const fixture = await mkdtemp(join(tmpdir(), "cmux-diff-freshness-idle-"));
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
const originalTimeout = globalThis.setTimeout;
const originalInterval = globalThis.setInterval;
let measuring = false;
let wakeups = 0;
let fingerprintReads = 0;
let gitCpuMs = 0;
let missingGitUsage = false;
let readError: unknown;
let lastRead = Promise.resolve("");
let unmount: (() => Promise<void>) | undefined;
const git = async (args: string[], measure = false) => {
  const child = spawn(["git", "-c", "core.hooksPath=/dev/null", ...args], {
    cwd: fixture,
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_SYSTEM: "/dev/null" },
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  if (code !== 0) throw new Error(`git ${args[0]}: ${stderr}`);
  if (measure) {
    const usage = child.resourceUsage();
    if (usage) gitCpuMs += Number(usage.cpuTime.total) / 1000;
    else missingGitUsage = true;
  }
  return stdout;
};
try {
  for (const [key, value] of Object.entries(replacements))
    Object.defineProperty(scope, key, { configurable: true, writable: true, value });
  Object.defineProperty(document, "hasFocus", { configurable: true, value: () => false });
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
  await git(["init", "-q"]);
  const contents = Array.from({ length: 256 }, (_, index) => `line ${index}`).join("\n") + "\n";
  await writeFile(join(fixture, "fixture.txt"), contents);
  await git(["add", "fixture.txt"]);
  await git(["-c", "user.name=Benchmark", "-c", "user.email=benchmark@example.invalid", "commit", "-qm", "fixture"]);
  await writeFile(join(fixture, "fixture.txt"), contents + "uncommitted edit\n");
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { useDiffFreshness } = await import(moduleURL.href);
  let initialReadDone = () => {};
  const initialRead = new Promise<void>((resolve) => {
    initialReadDone = resolve;
  });
  const read = () => {
    const measure = measuring;
    if (measure) fingerprintReads++;
    return (lastRead = git(["diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--"], measure)
      .then((patch) => createHash("sha256").update(patch).digest("hex"))
      .catch((error) => {
        readError = error;
        throw error;
      })
      .finally(initialReadDone));
  };
  type Callback = (...args: unknown[]) => void;
  type Timer = (callback: Callback, delay?: number, ...args: unknown[]) => ReturnType<typeof setTimeout>;
  const instrument =
    (schedule: Timer): Timer =>
    (callback, delay, ...args) => {
      const fromHook = new Error().stack?.includes(moduleURL.pathname) ?? false;
      const fire = (...values: unknown[]) => {
        if (fromHook && measuring) wakeups++;
        callback(...values);
      };
      return schedule(fire, delay, ...args);
    };
  globalThis.setTimeout = instrument(originalTimeout as unknown as Timer) as typeof setTimeout;
  globalThis.setInterval = instrument(originalInterval as unknown as Timer) as typeof setInterval;
  const noRefresh = () => false;
  const noop = () => {};
  function Viewer() {
    useDiffFreshness(read, 0, noRefresh, noop);
    return null;
  }
  const root = createRoot(document.getElementById("root")!);
  unmount = async () => {
    await act(async () => root.unmount());
  };
  await act(async () => {
    root.render(<Viewer />);
  });
  await initialRead;
  if (readError) throw readError;
  const cpuStart = process.cpuUsage();
  const started = performance.now();
  measuring = true;
  await new Promise<void>((resolve) => originalTimeout(resolve, durationMs));
  measuring = false;
  const elapsedMs = performance.now() - started;
  await unmount();
  unmount = undefined;
  await lastRead.catch(() => {});
  const cpu = process.cpuUsage(cpuStart);
  if (readError) throw readError;
  const result = {
    harness: "mounted-visible-unfocused-hook-and-git",
    module: moduleURL.pathname,
    durationMs,
    elapsedMs,
    wakeups,
    fingerprintReads,
    parentCpuMs: (cpu.user + cpu.system) / 1000,
    gitCpuMs: missingGitUsage ? null : gitCpuMs,
    initialLoadExcluded: true,
  };
  console.log(JSON.stringify(result));
} finally {
  measuring = false;
  await unmount?.();
  await lastRead.catch(() => {});
  globalThis.setTimeout = originalTimeout;
  globalThis.setInterval = originalInterval;
  dom.window.close();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
  await rm(fixture, { recursive: true, force: true });
}
