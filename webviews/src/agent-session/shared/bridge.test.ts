import { expect, test } from "bun:test";
import {
  __receiveAgentEventForTests,
  __resetAgentBridgeForTests,
  subscribeToAgentEvents,
} from "./bridge";
import type { AgentEvent } from "./types";

const inputAcceptedEvent: AgentEvent = {
  type: "provider.inputAccepted",
  providerId: "codex",
  sessionId: "session-1",
  text: "queued before listener",
  sentAtMs: 1_850_000_000_001,
};

test("native events received before subscription replay once", () => {
  __resetAgentBridgeForTests();
  __receiveAgentEventForTests(inputAcceptedEvent);

  const received: AgentEvent[] = [];
  const unsubscribe = subscribeToAgentEvents((event) => received.push(event));
  unsubscribe();

  const lateSubscriberEvents: AgentEvent[] = [];
  subscribeToAgentEvents((event) => lateSubscriberEvents.push(event))();

  expect(received).toEqual([inputAcceptedEvent]);
  expect(lateSubscriberEvents).toEqual([]);
  __resetAgentBridgeForTests();
});

test("native events received after subscription deliver immediately", () => {
  __resetAgentBridgeForTests();
  const received: AgentEvent[] = [];
  const unsubscribe = subscribeToAgentEvents((event) => received.push(event));

  __receiveAgentEventForTests(inputAcceptedEvent);

  expect(received).toEqual([inputAcceptedEvent]);
  unsubscribe();
  __resetAgentBridgeForTests();
});
