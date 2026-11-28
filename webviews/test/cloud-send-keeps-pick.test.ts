// Austin (c-17e4ae3662): "make sure that the model picker reflects the model and reasoning that we sent out the cloud
// chat under, sometimes it changes to a different model provider and stuff without me doing anyhtjng. The user picks
// it, dont change what thr hser picks, always persist it". A Cloud send names the model and reasoning the picker
// shows, so the machine starts on them and the Cloud chat's picker keeps them.
import { expect, test } from "bun:test";
import { cloudSendModel } from "../src/agent-session/acpmux/cloudModePick";
import { cloudPickExtras } from "../src/agent-session/acpmux/cloudRun";

const none = { held: undefined, shown: undefined, harness: undefined, remembered: undefined, face: undefined };

test("a Cloud send names the model the picker's face draws when the chat reported none", () => {
  // Before: no model went, and the machine started on its own default (the picker then changed to it).
  expect(cloudSendModel({ ...none, harness: "codex", shown: "default", face: "gpt-6-astra" })).toBe("gpt-6-astra");
  expect(cloudSendModel({ ...none, harness: "codex", face: "gpt-6-astra" })).toBe("gpt-6-astra");
});

test("a held or reported pick wins over the face, and a default names no model", () => {
  expect(cloudSendModel({ ...none, harness: "codex", held: "gpt-6-sol", shown: "gpt-6-astra", face: "x" })).toBe(
    "gpt-6-sol",
  );
  expect(cloudSendModel({ ...none, harness: "codex", shown: "gpt-6-astra", face: "x" })).toBe("gpt-6-astra");
  expect(cloudSendModel({ ...none, harness: "codex", face: "default" })).toBeUndefined();
  expect(cloudSendModel({ ...none, harness: "codex", face: "Default" })).toBeUndefined();
});

test("before the picker has a harness, the last local pick goes, as before (cmux#51731)", () => {
  expect(cloudSendModel({ ...none, remembered: "gpt-6-astra", face: "claude-opus-5-5" })).toBe("gpt-6-astra");
  expect(cloudSendModel({ ...none, remembered: "default" })).toBeUndefined();
});

test("a level picked before the session reports its effort goes with the Cloud start", () => {
  const configOptions = [{ id: "effort", category: "thought_level", currentValue: "high" }];
  // Before: summary.effort was unset, so the start named no level and the machine used its own.
  expect(cloudPickExtras({ configOptions })).toEqual({ effort: "high" });
  expect(cloudPickExtras({ effort: "low", configOptions })).toEqual({ effort: "low" });
  expect(cloudPickExtras({ configOptions: [{ id: "effort", currentValue: "default" }] })).toEqual({});
  expect(cloudPickExtras({ configOptions: [{ id: "model", currentValue: "high" }] })).toEqual({});
  expect(cloudPickExtras(undefined)).toEqual({});
});
