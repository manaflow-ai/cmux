// l10n-allow-file: test fixture prompts and host words, not shipped UI.
// Leo, 2026-11-09: "I can't click into the composer at all to, like potentially type other stuff
// while it's doing that initial load situation." A Cloud start locks the composer until the host
// answers `cloud.startChat`, and nothing on the host bounds a whole start, so a start that never
// answered looked like a start for good. The composer is open throughout now (#39913) and what is
// typed moves to the chat as a draft. A start with no word from the host for CLOUD_START_STALL_MS
// stalls: the card says where it stopped and that typing carries over.
import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { cloudStartFolder } from "../src/agent-session/acpmux/cloudRun";
import {
  CLOUD_START_STALL_MS,
  cloudStartBegun,
  cloudStartEnded,
  cloudStartPushed,
  cloudStartStalled,
  watchCloudStartStall,
  type CloudStartProgress,
} from "../src/agent-session/acpmux/cloudStartProgress";
import { CloudStartView } from "../src/agent-session/acpmux/CloudStartView";
import gallery from "../src/agent-session/acpmux/composerCloudStart.gallery";

const begun = () => cloudStartBegun("k-1", "fix the build", "/Users/me/src/paint");

/// A schedule the test runs by hand: what is armed, for how long, and whether it was disarmed.
function manualSchedule() {
  const armed: { run: () => void; ms: number; disarmed: boolean }[] = [];
  return {
    armed,
    schedule: (run: () => void, ms: number) => {
      const entry = { run, ms, disarmed: false };
      armed.push(entry);
      return () => {
        entry.disarmed = true;
      };
    },
  };
}

test("silence from the host for the stall time stalls the start that was out", () => {
  const { armed, schedule } = manualSchedule();
  let current: CloudStartProgress | undefined = begun();
  const disarm = watchCloudStartStall(
    current,
    (key) => (current = cloudStartStalled(current, key)),
    CLOUD_START_STALL_MS,
    schedule,
  );
  expect(armed).toHaveLength(1);
  expect(armed[0]!.ms).toBe(CLOUD_START_STALL_MS);
  // Minutes, longer than a new machine's 180 s link wait, so a healthy boot never trips it.
  expect(CLOUD_START_STALL_MS).toBeGreaterThan(180_000);
  armed[0]!.run();
  expect(current?.stalled).toBe(true);
  disarm();
  expect(armed[0]!.disarmed).toBe(true);
});

test("a stall only counts while nothing waits on the person, and only for its own start", () => {
  const { armed, schedule } = manualSchedule();
  const stall = () => undefined;
  const asking: CloudStartProgress = {
    ...begun(),
    ask: {
      id: "a",
      kind: "firstLogin",
      title: "Log in",
      lines: [],
      buttons: [{ id: "ok", title: "OK", role: "default" }],
    },
  };
  watchCloudStartStall(asking, stall, CLOUD_START_STALL_MS, schedule);
  watchCloudStartStall({ ...begun(), signingIn: true }, stall, CLOUD_START_STALL_MS, schedule);
  watchCloudStartStall(undefined, stall, CLOUD_START_STALL_MS, schedule);
  watchCloudStartStall(
    cloudStartEnded(begun(), "k-1", { ok: false, code: "cloud_start_failed" }),
    stall,
    CLOUD_START_STALL_MS,
    schedule,
  );
  expect(armed).toHaveLength(0);
  // A late timer for another start, or for one waiting on the person, changes nothing.
  expect(cloudStartStalled(begun(), "k-2")).toEqual(begun());
  expect(cloudStartStalled(asking, "k-1")).toBe(asking);
});

/// RED before: the timer re-armed on every push, and a copy pushes about 4 lines a second, so a copy
/// that sat at "0 of 46,516 files" for 20 minutes never stalled. Now only a push that moves the start
/// (a step, a phase, a count) puts the stall off.
test("a start whose pushes repeat the same progress stalls; one that moves does not", () => {
  const { armed, schedule } = manualSchedule();
  const t0 = 1_000_000;
  const copying = {
    key: "k-1",
    step: "folder",
    clone: { state: "running", phase: "copy", progress: { files_done: 0, files_total: 46_516 } },
  };
  let current = cloudStartPushed(begun(), copying, t0);
  expect(current?.advancedAt).toBe(t0);
  // Four minutes of the same line: no movement, so the start's clock does not reset.
  for (let second = 1; second <= 240; second += 1) current = cloudStartPushed(current, copying, t0 + second * 1000);
  expect(current?.advancedAt).toBe(t0);
  watchCloudStartStall(current, () => undefined, CLOUD_START_STALL_MS, schedule, t0 + 240_000);
  expect(armed.at(-1)!.ms).toBe(CLOUD_START_STALL_MS - 240_000);
  // Long past the stall time, a repeat still arms at once.
  watchCloudStartStall(current, () => undefined, CLOUD_START_STALL_MS, schedule, t0 + CLOUD_START_STALL_MS + 5_000);
  expect(armed.at(-1)!.ms).toBe(0);
  // A file landed: the start moved, and the full stall time starts again.
  const moved = { ...copying, clone: { ...copying.clone, progress: { files_done: 1, files_total: 46_516 } } };
  current = cloudStartPushed(current, moved, t0 + 300_000);
  expect(current?.advancedAt).toBe(t0 + 300_000);
  watchCloudStartStall(current, () => undefined, CLOUD_START_STALL_MS, schedule, t0 + 300_000);
  expect(armed.at(-1)!.ms).toBe(CLOUD_START_STALL_MS);
  // A new phase moves it too.
  const folders = {
    ...copying,
    clone: { state: "running", phase: "folders", progress: { objects: 10, objects_total: 4706 } },
  };
  expect(cloudStartPushed(current, folders, t0 + 310_000)?.advancedAt).toBe(t0 + 310_000);
});

/// Files and bytes under `folder` (what a start that names it as `cwd` sends to be copied).
function folderSize(folder: string): { files: number; bytes: number } {
  let files = 0;
  let bytes = 0;
  for (const entry of readdirSync(folder, { withFileTypes: true })) {
    const path = join(folder, entry.name);
    if (entry.isDirectory()) {
      const inner = folderSize(path);
      files += inner.files;
      bytes += inner.bytes;
    } else {
      files += 1;
      bytes += statSync(path).size;
    }
  }
  return { files, bytes };
}

/// Before/after harness (port of 2862f9df6ae). (a) A "No folder" tab reports Chief's home as its
/// folder: what that start sends to be copied, measured on a fake Chief home. (b) A copy stuck at
/// "0 of 46,516 files" that re-reports four times a second, on a virtual clock: when the stall shows.
test("measure: a no-folder start copies nothing, and a repeating stuck copy stalls on time", () => {
  const root = mkdtempSync(join(tmpdir(), "cloud-nofolder-"));
  try {
    const chiefHome = join(root, ".cmux", "chief", "default");
    for (let dir = 0; dir < 20; dir += 1) {
      mkdirSync(join(chiefHome, "sessions", `s${dir}`), { recursive: true });
      for (let file = 0; file < 10; file += 1)
        writeFileSync(join(chiefHome, "sessions", `s${dir}`, `f${file}.jsonl`), "x".repeat(4096));
    }
    const sent = cloudStartFolder(chiefHome);
    const copied = "cwd" in sent ? folderSize(sent.cwd) : { files: 0, bytes: 0 };

    // Virtual clock: timers fire when the clock passes them; App.tsx disarms and re-arms on every push.
    const timers: { at: number; run: () => void; live: boolean }[] = [];
    let now = 0;
    const schedule = (run: () => void, ms: number) => {
      const timer = { at: now + ms, run, live: true };
      timers.push(timer);
      return () => {
        timer.live = false;
      };
    };
    const stuck = {
      key: "k-1",
      step: "folder",
      clone: { state: "running", phase: "copy", progress: { files_done: 0, files_total: 46_516 } },
    };
    let current: CloudStartProgress | undefined = cloudStartPushed(begun(), stuck, now);
    let stalledAt: number | undefined;
    const arm = () =>
      watchCloudStartStall(
        current,
        (key) => {
          current = cloudStartStalled(current, key);
          stalledAt ??= now;
        },
        CLOUD_START_STALL_MS,
        schedule,
        now,
      );
    let disarm = arm();
    const horizon = 30 * 60_000;
    for (now = 250; now <= horizon && stalledAt === undefined; now += 250) {
      for (const timer of timers)
        if (timer.live && timer.at <= now) {
          timer.live = false;
          timer.run();
        }
      if (stalledAt !== undefined) break;
      disarm();
      current = cloudStartPushed(current, stuck, now);
      disarm = arm();
    }
    const stall = stalledAt === undefined ? `never within ${horizon / 60_000} min` : `${stalledAt / 1000} s`;
    console.log(
      `MEASURE no-folder copy: ${copied.files} files, ${copied.bytes} bytes; stuck-copy stall reported: ${stall}`,
    );
    expect(copied).toEqual({ files: 0, bytes: 0 });
    expect(stalledAt).toBe(CLOUD_START_STALL_MS);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("the stalled card says plainly that what is typed moves to the chat as a draft", () => {
  const markup = renderToStaticMarkup(<CloudStartView start={{ ...begun(), step: "machine", stalled: true }} bubble />);
  expect(markup).toContain("what you type here moves to it as a draft");
  expect(markup).not.toContain("is lost");
  expect(markup).not.toContain("You can type again");
});

test("a stalled start keeps the composer open as its steps still move, and ends as usual", () => {
  const stalled = cloudStartStalled(begun(), "k-1");
  const pushed = cloudStartPushed(stalled, { key: "k-1", step: "folder", machine: "paint-dev" });
  expect(pushed).toMatchObject({ step: "folder", machine: "paint-dev", stalled: true });
  // The chat opened after all: no card (this tab closes).
  expect(cloudStartEnded(pushed, "k-1", { ok: true })).toBeUndefined();
  // It failed after all: a failed card, no longer stalled.
  const failed = cloudStartEnded(pushed, "k-1", { ok: false, code: "cloud_start_failed", message: "No machine." });
  expect(failed?.state).toBe("failed");
  expect(failed?.stalled).toBeUndefined();
});

test("the stalled card says where the start stopped and that typing carries over", () => {
  const markup = renderToStaticMarkup(<CloudStartView start={{ ...begun(), step: "machine", stalled: true }} bubble />);
  expect(markup).toContain('data-stalled="true"');
  expect(markup).toContain("Set up a Cloud machine");
  expect(markup).toContain(String(CLOUD_START_STALL_MS / 60_000));
  // A question the host asks after the stall takes the card's word: the stall line goes.
  const asked = renderToStaticMarkup(
    <CloudStartView
      start={{
        ...begun(),
        stalled: true,
        ask: {
          id: "a",
          kind: "firstLogin",
          title: "Log in",
          lines: [],
          buttons: [{ id: "ok", title: "OK", role: "default" }],
        },
      }}
    />,
  );
  expect(asked).not.toContain('data-stalled="true"');
  // Still starting, the card reads as a first turn and says nothing of a stall.
  expect(renderToStaticMarkup(<CloudStartView start={{ ...begun(), step: "machine" }} bubble />)).not.toContain(
    "data-stalled",
  );
});

test("the gallery draws the composer starting, stalled, failed and more", () => {
  const variants = Object.keys(gallery.variants ?? {});
  expect(variants.length).toBeGreaterThan(2);
  expect(variants).toEqual(expect.arrayContaining(["starting", "stalled", "failed"]));
});
