/**
 * The Cloud surface of the terminal scroll-integrity probe (hq goals/terminal-scroll-integrity.md: "A scroll-stress
 * probe on local, SSH and Cloud terminals shows 0 blank or missing rows and 0 viewport jumps while scrolled up").
 *
 * Local and SSH run in cmux's perf cron (scripts/measure/terminal-scroll-stress-linux.sh). Cloud needs a machine and
 * a person's credential, which only the Cloud journey has, so it rides the journey: after the carrier dial,
 * `cmux carrier serve --machine VM --socket S` puts the carrier behind a Unix socket the way the app's bundled CLI
 * uses it, and `cmux __scroll-probe --socket S --surface-label cloud --json` (cmux-tui/crates/cmux-tui/src/scroll_probe.rs)
 * runs its stream in a terminal on the machine and reads it back over that link, scrolled up.
 *
 * The facts are counts only (probe.json is public): blank rows, missing rows and jumps for the byte mirror and the
 * daemon's render viewport, and their sum `bad`. hq's cloud_journey_probe.py carries them to NOW's terminal_scroll.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

export type ScrollViewCounts = { blank_rows: number; missing_rows: number; jumps: number };
export type CloudScrollFacts = {
  bad: number;
  mirror: ScrollViewCounts;
  daemon: ScrollViewCounts;
  seconds: number | null;
  pruned: boolean | null;
};

const count = (v: unknown): number | null => (typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : null);

/** The public counts of one `__scroll-probe --json` report, or why the report is not one. */
export function scrollProbeFacts(stdout: string): CloudScrollFacts | string {
  const line = stdout.trim().split("\n").filter(Boolean).pop();
  if (!line) return "the probe printed no report";
  let r: any;
  try {
    r = JSON.parse(line);
  } catch {
    return `not a JSON report: ${line.slice(0, 120)}`;
  }
  const view = (name: "mirror" | "daemon"): ScrollViewCounts | null => {
    const v = r?.views?.[name];
    const blank = count(v?.blank_rows), missing = count(v?.missing_rows), jumps = count(v?.jumps);
    return blank === null || missing === null || jumps === null ? null : { blank_rows: blank, missing_rows: missing, jumps };
  };
  const mirror = view("mirror"), daemon = view("daemon"), bad = count(r?.bad);
  if (!mirror || !daemon || bad === null) return "the report has no counts for both views";
  const seconds = typeof r?.seconds === "number" && Number.isFinite(r.seconds) ? Math.round(r.seconds * 10) / 10 : null;
  return { bad, mirror, daemon, seconds, pruned: typeof r?.stream?.pruned === "boolean" ? r.stream.pruned : null };
}

/** A step detail for the facts. */
export function scrollProbeDetail(f: CloudScrollFacts): string {
  const v = (c: ScrollViewCounts) => `${c.blank_rows} blank, ${c.missing_rows} missing, ${c.jumps} jumps`;
  return `bad ${f.bad} (mirror ${v(f.mirror)}; daemon ${v(f.daemon)})${f.seconds === null ? "" : ` in ${f.seconds} s`}${f.pruned ? "; scrollback pruned" : ""}`;
}

/** The first line a stream writes, or null when it ends or `ms` pass first. */
function firstLine(stream: NodeJS.ReadableStream, ms: number): Promise<string | null> {
  return new Promise((resolve) => {
    let buffered = "";
    const done = (line: string | null) => {
      clearTimeout(timer);
      stream.removeListener("data", onData);
      resolve(line);
    };
    const onData = (chunk: Buffer | string) => {
      buffered += chunk.toString();
      const at = buffered.indexOf("\n");
      if (at >= 0) done(buffered.slice(0, at));
    };
    const timer = setTimeout(() => done(null), ms);
    stream.on("data", onData);
    stream.once("end", () => done(null));
  });
}

/**
 * Runs the probe over `carrier serve` for `machine`. Never throws for a probe that could not run: it answers why
 * (the journey records that as a skip, so a measurement problem never fails the first-text journey).
 * `track` gets each child so a cancelled journey can stop it.
 */
export async function runCloudScrollProbe(
  cmux: string,
  api: { origin: string; bearer: string; team?: string | null },
  machine: string,
  track: (child: ChildProcess) => void = () => undefined,
  timeoutS = 240,
): Promise<{ facts: CloudScrollFacts } | { why: string }> {
  const dir = mkdtempSync(path.join(tmpdir(), "cmux-scroll-"));
  const socket = path.join(dir, "s.sock");
  const { CMUX_CLOUD_TEAM: _inherited, ...inherited } = process.env;
  const env = { ...inherited, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer, CMUX_TUI_STATE_DIR: dir };
  const children: ChildProcess[] = [];
  const start = (args: string[]) => {
    const child = spawn(cmux, args, { env, stdio: ["pipe", "pipe", "pipe"] });
    child.on("error", () => undefined);
    children.push(child);
    track(child);
    return child;
  };
  try {
    const serve = start(["carrier", "serve", "--machine", machine, "--socket", socket, "--deadline-ms", "90000", ...(api.team ? ["--team", api.team] : [])]);
    const ready = await firstLine(serve.stderr!, 30_000);
    let status: any = null;
    try {
      status = ready ? JSON.parse(ready) : null;
    } catch {
      /* not JSON: reported below */
    }
    if (status?.ok !== true) return { why: `carrier serve: ${ready === null ? "no ready line within 30 s" : ready.slice(0, 200)}` };
    // Each accepted connection's line goes to stderr; drain it so the pipe never fills.
    serve.stderr!.resume();
    const probe = start(["__scroll-probe", "--socket", socket, "--surface-label", "cloud", "--json", "--timeout-seconds", String(timeoutS)]);
    let out = "", err = "";
    probe.stdout!.on("data", (c) => (out += c.toString()));
    probe.stderr!.on("data", (c) => (err = (err + c.toString()).slice(-2000)));
    const code = await new Promise<number | null>((resolve) => {
      const timer = setTimeout(() => {
        probe.kill("SIGTERM");
        resolve(null);
      }, (timeoutS + 60) * 1000);
      probe.once("exit", (c) => {
        clearTimeout(timer);
        resolve(c);
      });
      probe.once("error", () => {
        clearTimeout(timer);
        resolve(-1);
      });
    });
    if (code !== 0) return { why: `__scroll-probe ${code === null ? `ran past ${timeoutS + 60} s` : `exit ${code}`}: ${err.trim().split("\n").slice(-3).join(" | ").slice(0, 300)}` };
    const facts = scrollProbeFacts(out);
    return typeof facts === "string" ? { why: facts } : { facts };
  } finally {
    for (const child of children) if (child.exitCode === null) child.kill("SIGTERM");
    rmSync(dir, { recursive: true, force: true });
  }
}
