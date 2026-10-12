import { afterEach, describe, expect, it } from "vitest";
import { extractSpawns, splitBubbles } from "../src/providers/chief.ts";
import { connectedCore, waitFor } from "./helpers.ts";

const cleanups: (() => void)[] = [];
afterEach(() => cleanups.splice(0).forEach((f) => f()));

describe("chief helpers", () => {
  it("splits bubbles on blank lines but not inside code fences", () => {
    expect(splitBubbles("Hi.\n\nSecond\nline\n\n\n```\na\n\nb\n```")).toEqual(["Hi.", "Second\nline", "```\na\n\nb\n```"]);
  });
  it("extracts spawn lines", () => {
    expect(extractSpawns("ok\n/spawn codex fix tests\nbye")).toEqual({ rest: "ok\nbye", spawns: [{ harness: "codex", task: "fix tests" }] });
  });
});

describe("ChiefProvider", () => {
  it("replies as bubbles with typing, spawns agents, and mirrors agent conversations", async () => {
    const { core, client } = await connectedCore();
    cleanups.push(() => core.shutdown());
    const messages: any[] = [];
    const typing: boolean[] = [];
    client.peer.on("event", (topic, p) => {
      if (topic === "conv.message") messages.push(p.message);
      if (topic === "conv.typing") typing.push(p.typing);
    });
    const { conversations } = await client.request("conv.list");
    expect(conversations.map((c: any) => c.id)).toEqual(["chief"]);
    const { message } = await client.request("conv.send", { conversationId: "chief", text: "please spawn something", clientId: "c-1" });
    expect(message).toMatchObject({ clientId: "c-1", sender: { isMe: true }, text: "please spawn something" });
    await waitFor(() => messages.some((m) => m.text.startsWith("Started Codex")));
    const fromChief = messages.filter((m) => m.conversationId === "chief" && !m.sender.isMe).map((m) => m.text);
    expect(fromChief).toEqual(["On it.", "Starting an agent now.", "Started Codex: fix the flaky test"]);
    expect(typing).toEqual([true, false]);
    // Chief's own ACP session is hidden from agent.list.
    const { sessions } = await client.request("agent.list");
    expect(sessions.map((s: any) => s.title)).toEqual(["fix the flaky test"]);
    // The spawned session gets its own conversation with prompt + final text.
    const convId = `agent:${sessions[0].id}`;
    await waitFor(() => messages.some((m) => m.conversationId === convId && m.text === "Hello world."));
    const hist = await client.request("conv.history", { conversationId: convId });
    expect(hist.messages.map((m: any) => [m.sender.isMe, m.text])).toEqual([
      [true, "fix the flaky test"],
      [false, "Hello world."],
    ]);
    const list = (await client.request("conv.list")).conversations;
    expect(list[0].id).toBe("chief"); // pinned
    expect(list.find((c: any) => c.id === convId)).toMatchObject({ kind: "agent", unread: 1 });
    await client.request("conv.read", { conversationId: convId });
    await client.request("conv.setMuted", { conversationId: convId, muted: true });
    expect((await client.request("conv.list")).conversations.find((c: any) => c.id === convId)).toMatchObject({ unread: 0, muted: true });
    const page = await client.request("conv.history", { conversationId: "chief", limit: 2 });
    expect(page).toMatchObject({ hasMore: true });
    expect(page.messages.length).toBe(2);
    await client.request("conv.delete", { conversationId: convId });
    expect((await client.request("conv.list")).conversations.map((c: any) => c.id)).toEqual(["chief"]);
  });
});
