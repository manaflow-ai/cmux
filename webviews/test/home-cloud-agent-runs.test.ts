// A Cloud group can have more than eight agent participants. Run history must include
// their reports without sending an unbounded burst of owner requests.
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
scope.window = dom.window;
scope.document = dom.window.document;
afterAll(() => {
  Object.assign(scope, saved);
  dom.window.close();
});

const { DaemonHomeClient } = await import("../src/pages/home-channels/daemonHome");
const { HomeOps } = await import("../src/pages/home-channels/types");
type Run = import("../src/pages/home-channels/types").HomeRun;

test("a Cloud group with 30 Chiefs returns all agent runs in at most eight concurrent owner reads", async () => {
  const conversation = "cloud-thirty-chiefs";
  const agents = Array.from({ length: 30 }, (_, index) => `agent_${String(index).padStart(2, "0")}`);
  const requested: string[] = [];
  let active = 0;
  let peak = 0;
  const socket = {
    async request<T>(command: string, params: Record<string, unknown> = {}): Promise<T> {
      if (command === "identify") return { capabilities: ["cloud-conversation-runs-v1"] } as T;
      if (command !== "cloud-conversation-runs") return {} as T;
      const agent = String(params.agent);
      requested.push(agent);
      active++;
      peak = Math.max(peak, active);
      try {
        // Let concurrent requests overlap so the test observes the admission bound.
        await Promise.resolve();
        return {
          runs: [{
            id: `run-${agent}`,
            conversation,
            author: agent,
            status: "done",
            started_at: 30,
            updated_at: 30,
            rev: 1,
            step_count: 0,
            answers: [],
          }],
          has_more: false,
        } as T;
      } finally {
        active--;
      }
    },
  };

  const home = new DaemonHomeClient(socket as never);
  const cloud = (
    home as unknown as {
      cloud: {
        known: Set<string>;
        entries: Map<string, Record<string, unknown>>;
        heads: Map<string, Record<string, unknown>>;
      };
    }
  ).cloud;
  cloud.known.add(conversation);
  cloud.entries.set(conversation, { conversation, kind: "group", title: "Thirty Chiefs" });
  cloud.heads.set(conversation, {
    id: conversation,
    participants: agents.map((id) => ({ id, kind: "agent", display_name: id })),
  });

  const page = await home.call<{ runs: Run[]; hasMore: boolean }>(HomeOps.runs, {
    conversation,
    limit: 20,
  });
  expect(requested).toEqual(agents);
  expect(page.runs).toHaveLength(30);
  expect(new Set(page.runs.map((run) => run.author))).toEqual(new Set(agents));
  expect(new Set(page.runs.map((run) => run.id)).size).toBe(30);
  expect(page.hasMore).toBe(false);
  expect(peak).toBeGreaterThan(0);
  expect(peak).toBeLessThanOrEqual(8);
});
