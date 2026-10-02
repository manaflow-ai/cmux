import { expect, test } from "bun:test";
import type { AcpmuxClient, Notification, SessionSummary } from "@mux/acpmux";
import { EVENT_PREFIX, PARENT_TAG, Supervisor } from "../src/supervisor.ts";

const agent = (
  status: SessionSummary["status"],
  tags: Record<string, string> = { [PARENT_TAG]: "mux" },
): SessionSummary => ({
  sessionId: "s1",
  name: "fixer",
  harness: "claude-sr",
  cwd: "/repo",
  status,
  pendingPermissions: 0,
  stateSeq: 1,
  preview: null,
  tags,
});

function fakeClient(sessions: SessionSummary[]) {
  const prompts: { session: string; text: string }[] = [];
  const client = {
    sessions: async () => sessions,
    watch: async () => ({}),
    onNotification: () => () => {},
    prompt: async (session: string, text: string) => {
      prompts.push({ session, text });
      return {};
    },
  } as unknown as AcpmuxClient;
  return { client, prompts };
}

const changed = (session: SessionSummary): Notification => ({
  method: "_acpmux/session_changed",
  params: { sessionId: session.sessionId, session },
});

test("a child's turn end reaches its mux once, with the reply; untagged sessions are ignored", async () => {
  const { client, prompts } = fakeClient([agent("running")]);
  const supervisor = new Supervisor(client, async () => "fixed the test");
  await supervisor.start();
  await supervisor.handle(changed(agent("running")));
  await supervisor.handle(changed(agent("ready")));
  await supervisor.handle(changed(agent("ready")));
  await supervisor.handle(changed({ ...agent("idle", {}), sessionId: "other" }));
  expect(prompts).toHaveLength(1);
  expect(prompts[0].session).toBe("mux");
  expect(prompts[0].text.startsWith(EVENT_PREFIX)).toBe(true);
  expect(prompts[0].text).toContain("fixed the test");
});

test("a child's permission request reaches its mux with the options to answer", async () => {
  const { client, prompts } = fakeClient([agent("waiting")]);
  const supervisor = new Supervisor(client, async () => "");
  await supervisor.start();
  await supervisor.handle({
    method: "_acpmux/permission_pending",
    params: {
      sessionId: "s1",
      permissionId: "p1",
      request: {
        toolCall: { title: "Run rm -rf build", rawInput: { command: "rm -rf build" } },
        options: [
          { optionId: "allow_once", name: "Allow" },
          { optionId: "reject_once", name: "Reject" },
        ],
      },
    },
  });
  expect(prompts).toHaveLength(1);
  expect(prompts[0].text).toContain("Run rm -rf build");
  expect(prompts[0].text).toContain("allow_once (Allow), reject_once (Reject)");
  expect(prompts[0].text).toContain("mux agents allow fixer OPTION_ID");
});
