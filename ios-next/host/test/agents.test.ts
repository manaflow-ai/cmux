import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { AgentsProvider } from "../src/providers/agents.ts";
import type { TranscriptItem } from "../src/protocol.ts";
import { connectedCore, fakeHarnesses, tempDir, waitFor } from "./helpers.ts";

const cleanups: (() => void)[] = [];
afterEach(() => cleanups.splice(0).forEach((f) => f()));

function provider(dir = tempDir()) {
  const p = new AgentsProvider({ harnesses: fakeHarnesses(), dir: join(dir, "sessions") });
  cleanups.push(() => p.shutdown());
  return { p, dir };
}

describe("AgentsProvider with a fake ACP agent", () => {
  it("lists harnesses, maps a turn into transcript items, and persists", async () => {
    const { p, dir } = provider();
    const items = new Map<string, TranscriptItem>();
    const order: string[] = [];
    p.on("event", (topic, payload: any) => {
      if (topic !== "agent.item") return;
      if (!items.has(payload.item.id)) order.push(payload.item.id);
      items.set(payload.item.id, payload.item);
    });
    const hs = await p.harnesses();
    expect(hs.map((h) => [h.id, h.available])).toEqual([
      ["claude", true],
      ["codex", true],
    ]);
    const s = await p.create({ harness: "claude", prompt: "do it" });
    expect(s.title).toBe("do it");
    const end = await waitFor(() => [...items.values()].find((i) => i.kind === "turnEnd"));
    expect(end).toMatchObject({ kind: "turnEnd", stopReason: "end_turn" });

    const kinds = order.map((id) => items.get(id)!.kind);
    expect(kinds).toEqual(["user", "thought", "plan", "tool", "assistant", "turnEnd"]);
    const thought = [...items.values()].find((i) => i.kind === "thought")!;
    expect(thought).toMatchObject({ text: "Thinking hard.", streaming: false });
    expect(typeof (thought as any).durationMs).toBe("number");
    expect([...items.values()].find((i) => i.kind === "assistant")).toMatchObject({ text: "Hello world.", streaming: false });
    expect(items.get("tool-t1")).toMatchObject({
      toolKind: "edit",
      title: "Edit a.txt",
      status: "completed",
      output: "done",
      locations: [{ path: "/tmp/a.txt", line: 3 }],
      diff: [{ path: "/tmp/a.txt", oldText: "a", newText: "b" }],
    });
    expect([...items.values()].find((i) => i.kind === "plan")).toMatchObject({ entries: [{ content: "Edit file", status: "in_progress", priority: "high" }] });

    const h = p.history(s.id);
    expect(h.commands).toEqual([{ name: "review", description: "Review code" }]);
    expect(h.session).toMatchObject({ status: "idle", mode: "default", preview: "Hello world." });
    expect((await p.harnesses())[0]!.modes.map((m) => m.id)).toEqual(["default", "plan"]);

    // Reload from disk in a fresh provider.
    p.shutdown();
    const { p: p2 } = provider(dir);
    const reloaded = p2.history(s.id);
    expect(reloaded.items.map((i) => i.kind)).toEqual(["user", "thought", "plan", "tool", "assistant", "turnEnd"]);
    expect(reloaded.session.status).toBe("idle");

    // A reloaded session can continue (fresh ACP context + notice).
    await p2.prompt(s.id, "again");
    await waitFor(() => p2.history(s.id).items.filter((i) => i.kind === "turnEnd").length === 2);
    const kinds2 = p2.history(s.id).items.map((i) => i.kind);
    expect(kinds2).toContain("notice");
  });

  it("surfaces permission requests and resolves them via agent.permission", async () => {
    const { core, client } = await connectedCore();
    cleanups.push(() => core.shutdown());
    const items = new Map<string, any>();
    const sessions: any[] = [];
    client.peer.on("event", (topic, p) => {
      if (topic === "agent.item") items.set(p.item.id, p.item);
      if (topic === "agent.session") sessions.push(p.session);
    });
    const { session } = await client.request("agent.create", { harness: "claude", prompt: "needs permission" });
    const perm = await waitFor(() => [...items.values()].find((i) => i.kind === "permission"));
    expect(perm).toMatchObject({ toolCallId: "t1", title: "Edit a.txt", options: [{ id: "allow", kind: "allow_once" }, { id: "deny", kind: "reject_once" }] });
    await waitFor(() => sessions.some((s) => s.status === "waiting"));
    await expect(client.request("agent.prompt", { sessionId: session.id, text: "x" })).rejects.toMatchObject({ code: "unavailable" });
    await client.request("agent.permission", { sessionId: session.id, itemId: perm.id, optionId: "allow" });
    await waitFor(() => [...items.values()].find((i) => i.kind === "turnEnd"));
    expect(items.get(perm.id).resolved).toBe("allow");
    const assistant = [...items.values()].filter((i) => i.kind === "assistant").map((i) => i.text).join("");
    expect(assistant).toContain("permission:selected:allow");
    const { sessions: list } = await client.request("agent.list");
    expect(list[0]).toMatchObject({ id: session.id, status: "idle" });
    await client.request("agent.setMode", { sessionId: session.id, modeId: "plan" });
    expect((await client.request("agent.history", { sessionId: session.id })).session.mode).toBe("plan");
    await client.request("agent.close", { sessionId: session.id });
    expect((await client.request("agent.list")).sessions[0].status).toBe("closed");
  });

  it("resolves a pending permission as cancelled on agent.cancel", async () => {
    const { core, client } = await connectedCore();
    cleanups.push(() => core.shutdown());
    const items = new Map<string, any>();
    client.peer.on("event", (topic, p) => topic === "agent.item" && items.set(p.item.id, p.item));
    const { session } = await client.request("agent.create", { harness: "claude", prompt: "needs permission" });
    const perm = await waitFor(() => [...items.values()].find((i) => i.kind === "permission"));
    await client.request("agent.cancel", { sessionId: session.id });
    await waitFor(() => items.get(perm.id).resolved === "cancelled");
    await waitFor(() => [...items.values()].find((i) => i.kind === "turnEnd"));
    const { items: history } = await client.request("agent.history", { sessionId: session.id });
    expect(history.find((i: any) => i.id === perm.id).resolved).toBe("cancelled");
  });

  it("refuses unavailable harnesses", async () => {
    const specs = fakeHarnesses();
    specs[1]!.detect = async () => false;
    const p = new AgentsProvider({ harnesses: specs, dir: join(tempDir(), "s") });
    await expect(p.create({ harness: "codex" })).rejects.toMatchObject({ code: "unavailable" });
    await expect(p.create({ harness: "nope" })).rejects.toMatchObject({ code: "bad_request" });
  });
});

describe("codex-acp terminal output meta", () => {
  it("accumulates terminal_output_delta into the tool output and notes non-zero exits", async () => {
    const { applyTerminalMeta } = await import("../src/providers/agents.ts");
    const acc = new Map<string, { tail: string; total: number }>();
    const item: any = { id: "tool-1", kind: "tool", toolKind: "execute", title: "t", status: "running", locations: [] };
    applyTerminalMeta(item, acc, { terminal_output_delta: { data: "stdout-42\n" } });
    applyTerminalMeta(item, acc, { terminal_output_delta: { data: "Darwin\n" }, terminal_exit: { exit_code: 0 } });
    expect(item.output).toBe("stdout-42\nDarwin\n");
    const failed: any = { id: "tool-2", kind: "tool", toolKind: "execute", title: "t", status: "running", locations: [] };
    applyTerminalMeta(failed, acc, { terminal_output_delta: { data: "nope\n" } });
    applyTerminalMeta(failed, acc, { terminal_exit: { exit_code: 2 } });
    expect(failed.output).toBe("nope\nexit 2");
    const silent: any = { id: "tool-3", kind: "tool", toolKind: "execute", title: "t", status: "running", locations: [] };
    applyTerminalMeta(silent, acc, { terminal_exit: { exit_code: 0 } });
    expect(silent.output).toBe("exit 0");
    expect(acc.size).toBe(0);
  });

  it("shows the tail of long streamed output with a count of what scrolled off", async () => {
    const { applyTerminalMeta } = await import("../src/providers/agents.ts");
    const acc = new Map<string, { tail: string; total: number }>();
    const item: any = { id: "tool-long", kind: "tool", toolKind: "execute", title: "t", status: "running", locations: [] };
    const chunk = "x".repeat(10_000) + "\n";
    for (let i = 0; i < 5; i++) applyTerminalMeta(item, acc, { terminal_output_delta: { data: chunk } });
    applyTerminalMeta(item, acc, { terminal_output_delta: { data: "LAST LINE\n" } });
    const total = chunk.length * 5 + "LAST LINE\n".length;
    const kept = 32 * 1024;
    expect(item.output.startsWith(`… ${total - kept} earlier characters\n`)).toBe(true);
    expect(item.output.endsWith("LAST LINE\n")).toBe(true);
    expect(acc.get("tool-long")!.tail.length).toBe(kept);
  });
});
