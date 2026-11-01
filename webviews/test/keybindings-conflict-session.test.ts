// Overwrite takes keys from the other actions one entry at a time, then saves them. Its writes
// outlive the click: while they run the person may start another row's recorder (a new session),
// and a failure of the removal then belongs to the recorder that asked, not to that one.
import { expect, test } from "bun:test";

test("a failed Overwrite removal does not put its refusal on another row's recorder", async () => {
  const { MockKeybindingsProvider } = await import("../src/pages/keybindings/mockProvider");
  const { KeybindingsStore } = await import("../src/pages/keybindings/store");
  const { KeybindingOps } = await import("../src/pages/keybindings/types");
  const { pageError } = await import("../src/pages/shared/pageClient");
  const provider = new MockKeybindingsProvider();
  const store = new KeybindingsStore(provider, { newKey: () => "key" });
  const settle = async () => {
    for (let i = 0; i < 6; i++) await Promise.resolve();
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
  };
  await store.start();
  const binding = (title: string) => store.getSnapshot().bindings.find((entry) => entry.title === title)!;
  const rowRecording = () => {
    const recording = store.getSnapshot().recording;
    return recording?.target === "row" ? recording : undefined;
  };

  // Keys Close Tab has: New Tab's recorder asks whether to overwrite.
  await store.changeKeybinding(binding("New Tab"));
  provider.press("cmd+w");
  provider.release();
  await settle();
  expect(rowRecording()?.prompt).toBeDefined();

  // Its removal of Close Tab's keys waits, then fails.
  let fail: () => void = () => undefined;
  const gate = new Promise<void>((resolve) => (fail = resolve));
  const call = provider.call.bind(provider);
  provider.call = (async (op: string, params: unknown) => {
    if (op === KeybindingOps.remove) {
      await gate;
      throw pageError("cmux.keybindings.write_failed", "keybindings.json is read-only");
    }
    return call(op, params);
  }) as typeof provider.call;
  const overwriting = store.resolveConflict("overwrite");
  await settle();

  // Meanwhile another row's recorder opens.
  await store.changeKeybinding(binding("Show History"));
  expect(rowRecording()?.binding.title).toBe("Show History");

  fail();
  await overwriting;
  await settle();
  expect(rowRecording()?.binding.title).toBe("Show History");
  expect(rowRecording()?.refusal).toBeUndefined();
  expect(rowRecording()?.warned).toBe(0);
});
