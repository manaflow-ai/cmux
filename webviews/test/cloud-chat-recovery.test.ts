import { describe, expect, test } from "bun:test";
import {
  cloudChatRecoveryActive,
  cloudChatState,
  cloudChatUnavailable,
} from "../src/agent-session/acpmux/cloudChatRecovery";
import { ChatUnavailableState } from "../src/agent-session/acpmux/ChatUnavailableState";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

const cloud = { id: "vm-demo", account: ["user", null] };
const inventory = (machines: unknown[]) => ({
  signedIn: true,
  loaded: true,
  complete: true,
  account: cloud.account,
  machines,
});
const paused = { id: cloud.id, name: "Demo machine", stage: "paused" };
const offline = { reason: "offline" as const, machine: "Demo machine" };

describe("cloud chat recovery", () => {
  test("transport loss preserves a cached transcript, but an empty native chat can recover", () => {
    expect(cloudChatRecoveryActive(false, "chat", 5, false)).toBe(false);
    expect(cloudChatRecoveryActive(false, "chat", 0, false)).toBe(true);
    expect(cloudChatRecoveryActive(false, "chat", 0, false, true)).toBe(false);
    expect(cloudChatRecoveryActive(false, "chat", 0, true)).toBe(false);
    expect(cloudChatRecoveryActive(false, undefined, 0, false)).toBe(false);
    expect(cloudChatRecoveryActive(true, "chat", 5, true)).toBe(true);
  });
  test("paused native VM offers Resume machine, while peers keep their existing state", () => {
    const state = cloudChatState(cloud, inventory([paused]));
    expect(state).toBe("paused");
    expect(cloudChatUnavailable(offline, state)).toEqual({
      reason: "paused",
      machine: "Demo machine",
    });
    expect(cloudChatUnavailable(offline, undefined)).toBe(offline);
  });
  test("destroyed or absent VM is deleted only in a loaded matching account", () => {
    for (const machines of [[], [{ ...paused, stage: "destroyed" }]]) {
      expect(cloudChatState(cloud, inventory(machines))).toBe("deleted");
    }
    for (const reply of [
      null,
      {},
      { ...inventory([]), loaded: false },
      { ...inventory([]), complete: false },
      { ...inventory([]), signedIn: false },
      { ...inventory([]), account: ["user", "another-team"] },
    ]) {
      expect(cloudChatState(cloud, reply)).toBeUndefined();
    }
  });
  test("a live machine falls back to the daemon's chat state", () => {
    expect(cloudChatState(cloud, inventory([{ ...paused, stage: "ready" }]))).toBe("live");
    expect(cloudChatUnavailable(offline, "live")).toBe(offline);
  });
  test("a failed stage keeps the native attach retry available", () => {
    const state = cloudChatState(cloud, inventory([{ ...paused, stage: "failed" }]));
    expect(state).toBe("paused");
    expect(cloudChatUnavailable(offline, state)).toEqual({ reason: "paused", machine: "Demo machine" });
  });
  test("the paused and deleted cards retain saved transcript recovery, without Reconnect", () => {
    const noop = () => {};
    for (const reason of ["paused", "machineDeleted"] as const) {
      const html = renderToStaticMarkup(
        createElement(ChatUnavailableState, {
          unavailable: { reason, machine: "Demo machine" },
          onRemove: noop,
          onReconnect: noop,
          onResumeMachine: noop,
          onResume: noop,
          onClose: noop,
        }),
      );
      expect(html).not.toContain('data-action="reconnect"');
      expect(html).toContain('data-action="resume"');
      expect(html.includes('data-action="resumeMachine"')).toBe(reason === "paused");
    }
  });
});
