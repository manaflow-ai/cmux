import { expect, test } from "bun:test";
import { CLOUD_WAKE_HINT_VERSION, CloudWakeHint } from "./cloudWakeHint";

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

test("a focus forwards the versioned raw signal for the shown machine", async () => {
  const calls: unknown[] = [];
  const hint = new CloudWakeHint({ call: async (method, params) => calls.push({ method, params }) });
  hint.signal(undefined);
  hint.signal("m-1");
  await flush();
  expect(calls).toEqual([
    { method: "cloudMachine.wakeHint", params: { v: CLOUD_WAKE_HINT_VERSION, id: "m-1", signal: "focus" } },
  ]);
});

test("the page does not debounce: the host's rules do", async () => {
  let n = 0;
  const hint = new CloudWakeHint({ call: async () => (n += 1) });
  hint.signal("m");
  hint.signal("m");
  await flush();
  expect(n).toBe(2);
});

test("an old host (no method) is asked once, then never again", async () => {
  for (const code of ["native.invalid_request", "unsupported"]) {
    let n = 0;
    const hint = new CloudWakeHint({
      call: () => {
        n += 1;
        return Promise.reject(Object.assign(new Error("no"), { code }));
      },
    });
    hint.signal("m");
    await flush();
    hint.signal("m");
    await flush();
    expect(n).toBe(1);
  }
});

test("a host that skipped or failed one hint is still asked next time", async () => {
  let n = 0;
  const hint = new CloudWakeHint({
    call: () => {
      n += 1;
      return Promise.reject(Object.assign(new Error("busy"), { code: "unavailable" }));
    },
  });
  hint.signal("m");
  await flush();
  hint.signal("m");
  await flush();
  expect(n).toBe(2);
});
