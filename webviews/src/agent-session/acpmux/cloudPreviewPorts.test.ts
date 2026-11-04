import { beforeEach, describe, expect, test } from "bun:test";
import {
  addCloudPreviewPort,
  cloudPreviewPorts,
  resetCloudPreviewPorts,
  seedCloudPreviewPorts,
  setCloudPreviewContext,
  subscribeCloudPreviewPorts,
} from "./cloudPreviewPorts";

describe("Cloud preview port cards", () => {
  beforeEach(() => resetCloudPreviewPorts());

  test("creates one card per new port", () => {
    setCloudPreviewContext({
      machineID: "machine-a",
      sessionId: "chat-a",
      turnId: "turn-a",
      active: true,
    });
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(true);
    expect(addCloudPreviewPort({ port: 3001, process: "node" })).toBe(true);
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(false);
    expect(cloudPreviewPorts()).toEqual([
      { port: 3000, process: "vite" },
      { port: 3001, process: "node" },
    ]);
  });

  test("does not add a card for a port already known by the machine", () => {
    setCloudPreviewContext({
      machineID: "machine-a",
      sessionId: "chat-a",
      turnId: "turn-a",
      active: true,
    });
    seedCloudPreviewPorts([{ port: 3000, process: "vite" }]);
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(false);
    expect(cloudPreviewPorts()).toEqual([]);
  });

  test("replayed snapshot ports during a turn seed the baseline without a card", () => {
    setCloudPreviewContext({
      machineID: "machine-a",
      sessionId: "chat-a",
      turnId: "turn-a",
      active: true,
    });
    expect(addCloudPreviewPort({ machineID: "machine-a", port: 3000, known: true })).toBe(false);
    expect(addCloudPreviewPort({ machineID: "machine-a", port: 3000 })).toBe(false);
    expect(cloudPreviewPorts()).toEqual([]);
    expect(addCloudPreviewPort({ machineID: "machine-a", port: 3001 })).toBe(true);
    expect(cloudPreviewPorts()).toEqual([{ port: 3001 }]);
  });

  test("replayed and snapshot-marked events never create a card", () => {
    setCloudPreviewContext({
      machineID: "machine-a",
      sessionId: "chat-a",
      turnId: "turn-a",
      active: true,
    });
    expect(addCloudPreviewPort({ port: 3000, replayed: true })).toBe(false);
    expect(addCloudPreviewPort({ data: { port: 3001, snapshot: true } })).toBe(false);
    expect(cloudPreviewPorts()).toEqual([]);
  });

  test("keeps the machine baseline when a new turn becomes active", () => {
    setCloudPreviewContext({
      machineID: "machine-a",
      sessionId: "chat-a",
      turnId: "turn-a",
      active: true,
    });
    expect(addCloudPreviewPort({ port: 3000 })).toBe(true);
    setCloudPreviewContext({
      machineID: "machine-a",
      sessionId: "chat-a",
      turnId: "turn-b",
      active: false,
    });
    expect(addCloudPreviewPort({ port: 3000 })).toBe(false);
    setCloudPreviewContext({
      machineID: "machine-a",
      sessionId: "chat-a",
      turnId: "turn-b",
      active: true,
    });
    expect(addCloudPreviewPort({ port: 3000 })).toBe(false);
    expect(cloudPreviewPorts()).toEqual([]);
  });

  test("ports discovered before the active turn are remembered but never shown", () => {
    setCloudPreviewContext({
      machineID: "machine-a",
      sessionId: "chat-a",
      turnId: "turn-a",
      active: false,
    });
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(false);
    setCloudPreviewContext({
      machineID: "machine-a",
      sessionId: "chat-a",
      turnId: "turn-a",
      active: true,
    });
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(false);
    expect(cloudPreviewPorts()).toEqual([]);
  });

  test("does not leak an event from another machine or session", () => {
    setCloudPreviewContext({
      machineID: "machine-a",
      sessionId: "chat-a",
      turnId: "turn-a",
      active: true,
    });
    expect(
      addCloudPreviewPort({
        port: 3000,
        machineID: "machine-b",
        sessionId: "chat-b",
        turnId: "turn-b",
      }),
    ).toBe(false);
    expect(cloudPreviewPorts()).toEqual([]);
    setCloudPreviewContext({
      machineID: "machine-b",
      sessionId: "chat-b",
      turnId: "turn-b",
      active: true,
    });
    expect(
      addCloudPreviewPort({
        port: 3000,
        machineID: "machine-b",
        sessionId: "chat-b",
        turnId: "turn-b",
      }),
    ).toBe(true);
    expect(cloudPreviewPorts()).toEqual([{ port: 3000 }]);
  });

  test("queues an event until the pane has a context, then applies it only to an active turn", () => {
    expect(addCloudPreviewPort({ port: 4173, process: "vite", sessionId: "chat-a" })).toBe(false);
    setCloudPreviewContext({
      machineID: "machine-a",
      sessionId: "chat-a",
      turnId: "turn-a",
      active: true,
    });
    expect(cloudPreviewPorts()).toEqual([{ port: 4173, process: "vite" }]);
  });

  test("an opened port can be shown again after a close event", () => {
    setCloudPreviewContext({
      machineID: "machine-a",
      sessionId: "chat-a",
      turnId: "turn-a",
      active: true,
    });
    expect(addCloudPreviewPort({ port: 3000, state: "up" })).toBe(true);
    expect(addCloudPreviewPort({ port: 3000, state: "down" })).toBe(false);
    expect(addCloudPreviewPort({ port: 3000, state: "up" })).toBe(true);
    expect(cloudPreviewPorts()).toEqual([{ port: 3000 }]);
  });

  test("a port closed in a later turn shows a card when it reopens in the next turn", () => {
    const turn = (turnId: string) =>
      setCloudPreviewContext({ machineID: "machine-a", sessionId: "chat-a", turnId, active: true });
    turn("turn-a");
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(true);
    turn("turn-b");
    expect(addCloudPreviewPort({ port: 3000, state: "closed" })).toBe(false);
    turn("turn-c");
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(true);
    expect(cloudPreviewPorts()).toEqual([{ port: 3000, process: "vite" }]);
  });

  test("notifies the pane when closed ports or a new turn remove cards", () => {
    const context = { machineID: "machine-a", sessionId: "chat-a", turnId: "turn-a", active: true };
    setCloudPreviewContext(context);
    const renderedPorts: number[][] = [];
    const unsubscribe = subscribeCloudPreviewPorts(() => {
      renderedPorts.push(cloudPreviewPorts().map((app) => app.port));
    });
    try {
      addCloudPreviewPort({ port: 3000 });
      addCloudPreviewPort({ port: 3000, state: "down" });
      addCloudPreviewPort({ port: 3001 });
      setCloudPreviewContext({ ...context, turnId: "turn-b" });
      expect(renderedPorts).toEqual([[3000], [], [3001], []]);
    } finally {
      unsubscribe();
    }
  });
});
