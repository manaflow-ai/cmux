// The Cloud page keeps its open machine, an unsent create sheet and the scroll of its list across a
// discard. The storefront view is the route's, which the page state puts back.
import { describe, expect, test } from "bun:test";
import { pageRoundTrip, scrollOf, withRestore } from "../shared/pageStateTesting";
import { MockCloudProvider } from "./mockProvider";
import { CLOUD_PAGE, CloudStore, restoredCloudInputs } from "./store";

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

async function started(store: CloudStore): Promise<() => void> {
  const unsubscribe = store.subscribe(() => undefined);
  for (let index = 0; index < 4; index += 1) await flush();
  return unsubscribe;
}

describe("Cloud page state", () => {
  test("a hide, a discard and a restore give the next document the same machine, sheet and scroll", async () => {
    const store = new CloudStore(new MockCloudProvider());
    const trip = pageRoundTrip(CLOUD_PAGE, {
      route: "#/get",
      scroll: { machines: 340 },
      inputs: () => store.pageInputs(),
    });
    const stop = await started(store);
    await store.select("vm_b2");
    store.openCreate(8192, true);
    store.updateDraft({ name: "build box" });
    stop();

    const { client, after } = trip.restore();
    expect(after.hash).toBe("#/get");
    const restored = new CloudStore(withRestore(new MockCloudProvider(), client));
    const stopRestored = await started(restored);
    expect(restored.getSnapshot().selection).toBe("vm_b2");
    expect(restored.getSnapshot().create).toMatchObject({ name: "build box", memoryMb: 8192, openWhenRunning: true });
    expect(scrollOf(after, "machines")).toBe(340);
    stopRestored();
  });

  test("a machine the team no longer has stays closed", async () => {
    const { client } = pageRoundTrip(CLOUD_PAGE, { inputs: () => ({ selection: "vm_gone" }) }).restore();
    const restored = new CloudStore(withRestore(new MockCloudProvider(), client));
    const stop = await started(restored);
    expect(restored.getSnapshot().selection).toBeUndefined();
    expect(restored.getSnapshot().create).toBeUndefined();
    stop();
  });

  test("only valid saved fields are taken", () => {
    expect(restoredCloudInputs({ selection: 3, create: { name: 1 } })).toEqual({});
    expect(
      restoredCloudInputs({
        selection: "vm",
        create: { name: "a", memoryMb: "big", from_snapshot: "", openWhenRunning: 1 },
      }),
    ).toEqual({ selection: "vm", create: { name: "a" } });
  });
});
