// A pane client (`AcpmuxDirectClient`) built without its constructor, for a test that drives one
// method: no socket, no host, no timers. The fields a publish and a reset read live here, in one
// place, so a field the client gains is added once rather than to each test's own list (each
// stub that missed one broke the test that reached it). A test passes only what it drives.
import { AcpmuxDirectClient, OrderedRows } from "../../src/agent-session/acpmux/direct";

/// The fields a publish reads (`emit`, `snapshot`), as an idle client with no chat has them.
function idleFields(): Record<string, unknown> {
  return {
    host: {},
    selectionGeneration: 0,
    trustCancellation: 0,
    closed: false,
    replayMode: false,
    fedMode: false,
    disposed: false,
    rows: new OrderedRows(),
    // The oldest record the chat holds, which every publish reads (heldFromAt).
    events: [],
    // The rail's indexed prompt slots, which every row publish reads (#42298).
    indexedPlaceholders: new Map(),
    supersededRowIds: new Set<string>(),
    sessions: [],
    askedSessions: [],
    asks: { sessions: () => undefined, list: () => [], listGrouped: () => [] },
    extensions: [],
    features: new Set<string>(),
    handoff: { state: {} },
    permissions: {
      state: { supported: false, ready: false, groups: [], chatAllowance: false, loading: false, busy: false },
    },
    queue: [],
    queueWithdrawn: [],
    waitingSteers: [],
    listener: () => undefined,
    // Where the chat's rows come from, which every publish and reset reads: v1, no chat on the store.
    chatRows: { view: () => undefined, holds: () => false, asks: () => false, close: () => undefined },
    subagents: {
      progressSource: { structureVersion: 0, takeChangedProgress: () => ({}) },
      views: () => [],
    },
  };
}

/// A client with the idle fields, then `fields` over them (a method a test replaces, the state it
/// starts from). A method not named keeps the prototype's.
export function directClientStub<T = AcpmuxDirectClient>(fields: Record<string, unknown> = {}): T {
  const client = Object.create(AcpmuxDirectClient.prototype) as AcpmuxDirectClient;
  Object.assign(client as unknown as Record<string, unknown>, idleFields(), fields);
  return client as unknown as T;
}
