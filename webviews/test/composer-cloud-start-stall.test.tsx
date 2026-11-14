// l10n-allow-file: test fixture prompts and host words, not shipped UI.
// Leo, 2026-11-09: "I can't click into the composer at all to, like potentially type other stuff
// while it's doing that initial load situation." A Cloud start locks the composer until the host
// answers `cloud.startChat`, and nothing on the host bounds a whole start, so a start that never
// answered looked like a start for good. The composer is open throughout now (#39913) and what is
// typed moves to the chat as a draft. A start with no word from the host for CLOUD_START_STALL_MS
// stalls: the card says where it stopped and that typing carries over.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
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
