// l10n-allow-file: test fixtures, not shipped UI.
// Lawrence 2026-11-09, on a chat's model menu: "switching to medium doesnt work". The menu checked
// Medium but the chip kept "Opus 5.5 Max", and the chat ran at Max. The chat had no session yet (a
// new chat, or one whose harness was still starting): the chip drew the effort option of the
// harness's last session (Max), while `chat.effort` checked the pick against acpmux's raw summary,
// which has no options before the session opens. It threw "the session offers no effort option",
// nobody caught it, and the pick was lost. A pick then must be held by the switch for the session
// it starts, as a model or mode pick is.
import { expect, test } from "bun:test";
import { pickEffort } from "../src/agent-session/acpmux/configurationActions";
import { HarnessSwitch } from "../src/agent-session/acpmux/harnessSwitch";

function starting() {
  const store = new HarnessSwitch();
  store.setHandlers({ notice: () => undefined } as never);
  const written: string[] = [];
  let open: (id: string) => void = () => undefined;
  store.connect({
    turnRunning: () => false,
    shown: () => undefined,
    create: () => new Promise<string>((resolve) => (open = resolve)),
    leave: () => undefined,
    open: async (sessionId: string) => sessionId,
    send: async () => undefined,
    setModel: async () => undefined,
    setMode: async () => undefined,
    setConfig: async (configId: string, value: string) => {
      written.push(`${configId}=${value}`);
    },
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  } as never);
  const opened = store.switchTo("claude", "/Users/dev", { model: "claude-opus-5-5" });
  return { store, written, opened, open: (id: string) => open(id) };
}

test("Medium picked while the chat's session is still starting runs on that session", async () => {
  const chat = starting();
  const direct: string[] = [];
  // acpmux's summary before the session opens: no config options yet.
  await pickEffort(
    { configId: "effort", value: "medium" },
    {
      summary: { configOptions: [] },
      switch: chat.store,
      setConfig: async (id, value) => {
        direct.push(`${id}=${value}`);
      },
    },
  );
  chat.open("s1");
  expect(await chat.opened).toBe("s1");
  expect(chat.written).toEqual(["effort=medium"]);
  expect(direct).toEqual([]);
});

test("a level picked on a live session still goes straight to it", async () => {
  const store = new HarnessSwitch();
  const written: string[] = [];
  store.connect({
    turnRunning: () => false,
    shown: () => undefined,
    setConfig: async (configId: string, value: string) => {
      written.push(`${configId}=${value}`);
    },
  } as never);
  await pickEffort(
    { configId: "effort", value: "medium" },
    {
      summary: {
        sessionId: "s1",
        configOptions: [{ id: "effort", category: "thought_level", currentValue: "max" }],
      },
      switch: store,
      setConfig: async () => undefined,
    },
  );
  expect(written).toEqual(["effort=medium"]);
});

test("with no chat starting and no session, the pick is refused", async () => {
  await expect(
    pickEffort(
      { configId: "effort", value: "medium" },
      { summary: undefined, switch: new HarnessSwitch(), setConfig: async () => undefined },
    ),
  ).rejects.toThrow("no effort option");
});
