import { describe, expect, test } from "bun:test";
import { imageRollWatch, liveDetail, liveProblem, liveWindow, readBootImage } from "./cloud-journey";

/** A fake clock: sleep moves it, each turn costs `turnMs`. */
function clock() {
  let t = 0;
  return { now: () => t, sleep: async (ms: number) => { t += ms; }, advance: (ms: number) => { t += ms; } };
}

describe("--live-until: a chat kept turning across a backend change", () => {
  test("stops once the watched image changed and settled, then takes one more turn", async () => {
    const c = clock();
    let image = "img-a";
    const watch = imageRollWatch({ read: async () => image, settleMs: 60_000, now: c.now });
    await watch.start();
    const w = await liveWindow({
      turn: async (i) => { c.advance(2_000); if (i === 3) image = "img-b"; },
      stop: () => watch.stop(),
      everyMs: 30_000, maxMs: 3_600_000, now: c.now, sleep: c.sleep,
    });
    expect(w.stopped_by).toBe("signal");
    expect(watch.state).toMatchObject({ from: "img-a", to: "img-b" });
    // Turns 1-3, the change seen after 3, two more turns until 60 s settle, then the turn after.
    expect(w.turns.length).toBe(6);
    expect(liveProblem(w)).toBeNull();
    expect(liveDetail(w, "roll img-a -> img-b")).toContain("6/6 turns answered");
  });

  test("a failed turn fails the window, and says whether the chat came back", async () => {
    const c = clock();
    const w = await liveWindow({
      turn: async (i) => { c.advance(1_000); if (i === 2) throw new Error("carrier closed"); },
      stop: async () => false,
      everyMs: 10_000, maxMs: 35_000, now: c.now, sleep: c.sleep,
    });
    expect(w.stopped_by).toBe("max");
    const p = liveProblem(w)!;
    expect(p).toContain("1 of");
    expect(p).toContain("carrier closed");
    expect(p).toContain("answered again by turn 3");
  });

  test("an unreadable list is no change; the window runs to its end", async () => {
    const c = clock();
    const watch = imageRollWatch({ read: async () => { throw new Error("offline"); }, settleMs: 0, now: c.now });
    await watch.start();
    const w = await liveWindow({ turn: async () => c.advance(500), stop: () => watch.stop(), everyMs: 5_000, maxMs: 20_000, now: c.now, sleep: c.sleep });
    expect(w.stopped_by).toBe("max");
    expect(watch.state.to).toBeNull();
  });

  test("readBootImage reads production's first entry and staging's last", async () => {
    const list = (ids: string[]) => JSON.stringify(JSON.stringify(ids.map((id) => ({ id, revision: "r1", displayName: id, snapshotId: "sh-x", services: ["s"] }))));
    const text = `{ "env": { "staging": { "vars": { "VM_BOOT_IMAGES": ${list(["s-old", "s-new"])} } }, "production": { "vars": { "VM_BOOT_IMAGES": ${list(["p-new", "p-old"])} } } } }`;
    expect(await readBootImage("staging", async () => text)).toBe("s-new");
    expect(await readBootImage("production", async () => text)).toBe("p-new");
  });
});
