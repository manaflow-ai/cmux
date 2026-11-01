// `debug.agent_pane` compose_send and run_mode: a capture drives the composer as a person does, so a
// new chat with Cloud picked starts on a Cloud machine (`cloud.startChat`). send_prompt goes to
// `chat.send` and never takes a Cloud start.
import { expect, test } from "bun:test";
import {
  composeSend,
  runMode,
  type AutomationCompose,
  type AutomationHost,
} from "../src/agent-session/acpmux/automation";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { RunMode } from "../src/agent-session/acpmux/sandboxRun";

function host(compose?: AutomationCompose): AutomationHost {
  return {
    snapshot: () => ({}) as AcpmuxSnapshot,
    call: async () => undefined,
    selectSession: () => undefined,
    openDiff: () => undefined,
    diff: () => ({ open: false, paths: [] }),
    ...(compose ? { compose } : {}),
  };
}

function composer(offered = true) {
  let mode: RunMode = "persistent";
  const sent: string[] = [];
  const compose: AutomationCompose = {
    async send(text) {
      sent.push(text);
      // A Cloud start keeps the prompt until its chat opens on the machine.
      return mode !== "cloud";
    },
    runMode: () => mode,
    setRunMode(next) {
      if (!offered) return false;
      mode = next;
      return true;
    },
    cloudStart: () => (mode === "cloud" && sent.length ? { state: "starting" } : null),
  };
  return { compose, sent };
}

test("compose_send sends through the composer and reports where it went", async () => {
  const { compose, sent } = composer();
  expect(runMode(host(compose), "cloud")).toEqual({ runMode: "cloud", cloudStart: null });
  expect(await composeSend(host(compose), "reply with CLOUD_OK")).toEqual({
    sent: false,
    runMode: "cloud",
    cloudStart: { state: "starting" },
  });
  expect(sent).toEqual(["reply with CLOUD_OK"]);
});

test("run_mode refuses an unknown place and a composer that offers none", () => {
  const { compose } = composer(false);
  expect(runMode(host(compose), "moon")).toEqual({ error: "mode must be one of persistent, sandboxed, cloud" });
  expect(runMode(host(compose), "cloud")).toEqual({ error: "the composer offers no run place now" });
  expect(runMode(host(compose))).toEqual({ runMode: "persistent", cloudStart: null });
});

test("compose_send says when no composer shows, and refuses an empty prompt", async () => {
  expect(await composeSend(host(), "hi")).toEqual({ error: "the page has no composer" });
  const none: AutomationCompose = { ...composer().compose, send: async () => undefined };
  expect(await composeSend(host(none), "hi")).toEqual({ error: "no composer shows (the New Tab page?)" });
  expect(await composeSend(host(none), "  ")).toEqual({ error: "empty prompt" });
});
