import { afterEach, expect, test } from "bun:test";
import {
  PLACE_CHAT_METHOD,
  autoTargets,
  decideAuto,
  keepCloudLanding,
  landingMove,
  landingOf,
  landingTextKey,
  parseAutoDecision,
  takeCloudLanding,
  whenSendRefused,
} from "./autoWhereModel";

// The daemon's replies as server/place.rs answers them (place_chat_tests.rs).
const OVER_BUDGET_TO_CLOUD = {
  placement: { at: "there", place: "cloud" },
  reason: { code: "over_budget", level: "warning", over: ["cpu"] },
  why: "this machine is over budget (Warning: cpu)",
  targets: 1,
};
const NO_ROOM_HERE = {
  placement: { at: "here" },
  reason: { code: "no_room", level: "warning", over: ["cpu"], places: [] },
  why: "this machine is over budget (Warning: cpu) and no other machine is available",
  targets: 0,
};

test("Cloud is a target only while offered and not known signed out", () => {
  expect(autoTargets({ cloudOffered: true })).toEqual([{ place: "cloud", headroom: "room" }]);
  expect(autoTargets({ cloudOffered: true, signedIn: true })).toEqual([{ place: "cloud", headroom: "room" }]);
  expect(autoTargets({ cloudOffered: true, signedIn: false })).toEqual([]);
  expect(autoTargets({ cloudOffered: false, signedIn: true })).toEqual([]);
});

test("a reply reads into a decision; anything else is none", () => {
  expect(parseAutoDecision(OVER_BUDGET_TO_CLOUD)?.placement).toEqual({ at: "there", place: "cloud" });
  expect(parseAutoDecision(NO_ROOM_HERE)?.placement).toEqual({ at: "here" });
  expect(parseAutoDecision(undefined)).toBeUndefined();
  expect(parseAutoDecision({ placement: { at: "there" }, reason: { code: "x" } })).toBeUndefined();
  expect(parseAutoDecision({ placement: { at: "here" }, reason: {} })).toBeUndefined();
  expect(parseAutoDecision("here")).toBeUndefined();
});

test("only Cloud is a place the page starts a chat on; any other place runs here", () => {
  expect(landingOf(parseAutoDecision(OVER_BUDGET_TO_CLOUD))).toEqual({
    went: "cloud",
    code: "over_budget",
    why: OVER_BUDGET_TO_CLOUD.why,
  });
  const elsewhere = parseAutoDecision({ ...OVER_BUDGET_TO_CLOUD, placement: { at: "there", place: "studio" } });
  expect(landingOf(elsewhere).went).toBe("here");
  expect(landingOf(undefined)).toEqual({ went: "here", code: "no_daemon" });
});

test("Auto asks the daemon with the targets as data, and never fails", async () => {
  const asked: unknown[] = [];
  const landing = await decideAuto(
    async (method, params) => {
      asked.push(method, params);
      return OVER_BUDGET_TO_CLOUD;
    },
    autoTargets({ cloudOffered: true }),
  );
  expect(asked).toEqual([PLACE_CHAT_METHOD, { where: "auto", targets: [{ place: "cloud", headroom: "room" }] }]);
  expect(landing.went).toBe("cloud");
  // No daemon serving it, a refusal, or a reply it can't read: here, and the line says why.
  expect(await decideAuto(undefined, [])).toEqual({ went: "here", code: "no_daemon" });
  expect(
    await decideAuto(async () => {
      throw new Error("refused");
    }, []),
  ).toEqual({ went: "here", code: "no_daemon" });
  expect(await decideAuto(async () => ({ nonsense: true }), [])).toEqual({ went: "here", code: "no_daemon" });
});

test("each landing has one plain sentence and the chat's own move back", () => {
  expect(landingTextKey({ went: "cloud", code: "over_budget" })).toBe("auto.wentCloud");
  expect(landingTextKey({ went: "here", code: "within_budget" })).toBe("auto.keptHere");
  expect(landingTextKey({ went: "here", code: "no_room" })).toBe("auto.keptHereNoCloud");
  expect(landingTextKey({ went: "here", code: "no_daemon" })).toBe("auto.keptHereUnread");
  expect(landingTextKey({ went: "here", code: "budget_unknown" })).toBe("auto.keptHereUnread");
  expect(landingMove({ went: "cloud", code: "over_budget" })).toBe("bringBack");
  expect(landingMove({ went: "here", code: "within_budget" })).toBe("move");
});

const scope = globalThis as Record<string, unknown>;
const savedStorage = scope.localStorage;
afterEach(() => {
  if (savedStorage === undefined) delete scope.localStorage;
  else scope.localStorage = savedStorage;
});
function memoryStorage(): Storage {
  const items = new Map<string, string>();
  return {
    get length() {
      return items.size;
    },
    clear: () => items.clear(),
    getItem: (key) => items.get(key) ?? null,
    key: (index) => [...items.keys()][index] ?? null,
    removeItem: (key) => void items.delete(key),
    setItem: (key, value) => void items.set(key, value),
  };
}

test("a Cloud landing is taken once, by the chat whose first prompt it is, while fresh", () => {
  scope.localStorage = memoryStorage();
  const landing = { went: "cloud" as const, code: "over_budget", why: "busy" };
  keepCloudLanding(landing, " fix the build ", 1000);
  expect(takeCloudLanding("another chat", 1000)).toBeUndefined();
  expect(takeCloudLanding("fix the build", 2000)).toEqual(landing);
  expect(takeCloudLanding("fix the build", 2000)).toBeUndefined();
  keepCloudLanding(landing, "fix the build", 0);
  expect(takeCloudLanding("fix the build", 31 * 60_000)).toBeUndefined();
});

test("a decided send that does not go clears the decision; one that goes keeps it", async () => {
  let cleared = 0;
  const clear = () => void (cleared += 1);
  whenSendRefused(false, clear);
  expect(cleared).toBe(1);
  whenSendRefused(true, clear);
  whenSendRefused(undefined, clear);
  await whenSendRefused(Promise.resolve(true), clear);
  expect(cleared).toBe(1);
  const refused = Promise.reject(new Error("refused"));
  whenSendRefused(refused, clear);
  await refused.catch(() => undefined);
  await Promise.resolve();
  expect(cleared).toBe(2);
});
