import { beforeEach, describe, expect, test } from "bun:test";
import {
  addCloudPreviewPort,
  cloudPreviewPorts,
  resetCloudPreviewPorts,
  seedCloudPreviewPorts,
  setCloudPreviewContext,
} from "./cloudPreviewPorts";

describe("Cloud preview port cards", () => {
  beforeEach(() => resetCloudPreviewPorts());

  test("creates one card per new port", () => {
    setCloudPreviewContext({ machineID: "machine-a", sessionId: "chat-a", turnId: "turn-a", active: true });
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(true);
    expect(addCloudPreviewPort({ port: 3001, process: "node" })).toBe(true);
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(false);
    expect(cloudPreviewPorts()).toEqual([
      { port: 3000, process: "vite" },
      { port: 3001, process: "node" },
    ]);
  });

  test("does not add a card for a port already known by the machine", () => {
    setCloudPreviewContext({ machineID: "machine-a", sessionId: "chat-a", turnId: "turn-a", active: true });
    seedCloudPreviewPorts([{ port: 3000, process: "vite" }]);
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(false);
    expect(cloudPreviewPorts()).toEqual([]);
  });

  test("ports discovered before the active turn are remembered but never shown", () => {
    setCloudPreviewContext({ machineID: "machine-a", sessionId: "chat-a", turnId: "turn-a", active: false });
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(false);
    setCloudPreviewContext({ machineID: "machine-a", sessionId: "chat-a", turnId: "turn-a", active: true });
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(false);
    expect(cloudPreviewPorts()).toEqual([]);
  });

  test("does not leak an event from another machine or session", () => {
    setCloudPreviewContext({ machineID: "machine-a", sessionId: "chat-a", turnId: "turn-a", active: true });
    expect(
      addCloudPreviewPort({ port: 3000, machineID: "machine-b", sessionId: "chat-b", turnId: "turn-b" }),
    ).toBe(false);
    expect(cloudPreviewPorts()).toEqual([]);
    setCloudPreviewContext({ machineID: "machine-b", sessionId: "chat-b", turnId: "turn-b", active: true });
    expect(addCloudPreviewPort({ port: 3000, machineID: "machine-b", sessionId: "chat-b", turnId: "turn-b" })).toBe(
      true,
    );
    expect(cloudPreviewPorts()).toEqual([{ port: 3000 }]);
  });

  test("queues an event until the pane has a context, then applies it only to an active turn", () => {
    expect(addCloudPreviewPort({ port: 4173, process: "vite", sessionId: "chat-a" })).toBe(false);
    setCloudPreviewContext({ machineID: "machine-a", sessionId: "chat-a", turnId: "turn-a", active: true });
    expect(cloudPreviewPorts()).toEqual([{ port: 4173, process: "vite" }]);
  });

  test("an opened port can be shown again after a close event", () => {
    setCloudPreviewContext({ machineID: "machine-a", sessionId: "chat-a", turnId: "turn-a", active: true });
    expect(addCloudPreviewPort({ port: 3000, state: "up" })).toBe(true);
    expect(addCloudPreviewPort({ port: 3000, state: "down" })).toBe(false);
    expect(addCloudPreviewPort({ port: 3000, state: "up" })).toBe(true);
    expect(cloudPreviewPorts()).toEqual([{ port: 3000 }]);
  });
});
