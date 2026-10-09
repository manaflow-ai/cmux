import { afterEach, describe, expect, it } from "vitest";
import { ScrollbackRing, TERM_HIGH_WATER, TERM_LOW_WATER, TerminalProvider } from "../src/providers/terminal.ts";
import { connectedCore, waitFor } from "./helpers.ts";

const providers: TerminalProvider[] = [];
afterEach(() => providers.splice(0).forEach((p) => p.closeAll()));

describe("ScrollbackRing", () => {
  it("drops oldest bytes past capacity", () => {
    const r = new ScrollbackRing(10);
    r.append(Buffer.from("abcdef"));
    r.append(Buffer.from("ghijkl"));
    expect(r.snapshot().toString()).toBe("cdefghijkl");
    r.append(Buffer.from("0123456789XYZ"));
    expect(r.snapshot().toString()).toBe("3456789XYZ");
  });
});

describe("TerminalProvider", () => {
  it("spawns a pty, echoes, and replays scrollback on attach", async () => {
    const p = new TerminalProvider({ shell: "/bin/sh", args: [] });
    providers.push(p);
    const t = p.create(80, 24);
    expect(t.running).toBe(true);
    let out = "";
    const detach = p.attach(t.id, 80, 24, (d) => (out += Buffer.from(d).toString()));
    p.write(t.id, new TextEncoder().encode("echo hi-$((40+2))\r"));
    await waitFor(() => out.includes("hi-42"));
    detach();
    let replay = "";
    p.attach(t.id, 100, 30, (d) => (replay += Buffer.from(d).toString()));
    expect(replay).toContain("hi-42");
    expect(p.list()[0]).toMatchObject({ cols: 100, rows: 30 });
  });

  it("pauses the pty above the high-water mark and resumes below low-water", async () => {
    const p = new TerminalProvider({ shell: "/bin/sh", args: [] });
    providers.push(p);
    const t = p.create(80, 24);
    let backlog = 0;
    let out = "";
    p.attach(t.id, 80, 24, (d) => (out += Buffer.from(d).toString()), () => backlog);
    const inst = p.get(t.id);
    p.write(t.id, new TextEncoder().encode("echo first-$((1+1))\r"));
    await waitFor(() => out.includes("first-2"));
    // The phone stops draining: the next output trips the high-water mark.
    backlog = TERM_HIGH_WATER + 1;
    p.write(t.id, new TextEncoder().encode("echo trip\r"));
    await waitFor(() => inst.paused).catch(() => { throw new Error("never paused"); });
    // While paused, output stays in the kernel buffer.
    p.write(t.id, new TextEncoder().encode("echo second-$((2+1))\r"));
    await new Promise((r) => setTimeout(r, 300));
    expect(out).not.toContain("second-3");
    backlog = TERM_LOW_WATER - 1;
    await waitFor(() => !inst.paused);
    await waitFor(() => out.includes("second-3")).catch(() => { throw new Error("no second: " + JSON.stringify(out)); });
  });

  it("reports exit", async () => {
    const p = new TerminalProvider({ shell: "/bin/sh", args: ["-c", "exit 3"] });
    providers.push(p);
    const events: [string, any][] = [];
    p.on("event", (topic, payload) => events.push([topic, payload]));
    const t = p.create(80, 24);
    const exited = await waitFor(() => events.find(([topic]) => topic === "term.exited"));
    expect(exited[1]).toEqual({ terminalId: t.id, code: 3 });
    expect(p.list()[0]!.running).toBe(false);
  });

  it("works end to end over RPC with two attachments", async () => {
    const { core, client } = await connectedCore({ terminal: { shell: "/bin/sh", args: [] } });
    try {
      const echo = await client.terminalEcho();
      expect(echo.marker).toMatch(/^cmux-probe-/);
      const { terminal } = await client.request("term.create", { cols: 80, rows: 24 });
      const a = await client.request("term.attach", { terminalId: terminal.id, cols: 80, rows: 24 });
      const b = await client.request("term.attach", { terminalId: terminal.id, cols: 90, rows: 24 });
      let outA = "";
      let outB = "";
      client.onStream(a.streamId, (d) => (outA += Buffer.from(d).toString()));
      client.onStream(b.streamId, (d) => (outB += Buffer.from(d).toString()));
      client.sendInput(a.streamId, "echo multi-$((1+1))\r");
      await waitFor(() => outA.includes("multi-2") && outB.includes("multi-2"));
      await client.request("term.detach", { streamId: a.streamId });
      await client.request("term.resize", { terminalId: terminal.id, cols: 120, rows: 40 });
      const { terminals } = await client.request("term.list");
      expect(terminals.find((t: any) => t.id === terminal.id)).toMatchObject({ cols: 120, rows: 40 });
      await expect(client.request("term.attach", { terminalId: "nope", cols: 1, rows: 1 })).rejects.toMatchObject({ code: "not_found" });
    } finally {
      core.shutdown();
    }
  });
});
