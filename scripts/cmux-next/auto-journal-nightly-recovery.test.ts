import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { assertJournalPrefix, assertMarker, assertRecovered, assertSnapshot, claudeLoginFromEnv, confirmDeleted, descendants, eventTuples, guestReadProgram, sameProcess, storeEvents, validateProvenance, verifyRuntimeFiles, waitStore } from "./auto-journal-nightly-recovery.ts";

const sha = "a".repeat(40), digest = "b".repeat(64);
const good = () => ({ source_sha: sha, daemon_source_sha: sha, contains_sha: "96ee46878c55c81ed64316b870a01cf6e3f2c71f", workflow_run: 45922207552, app_build: "4592220755201", artifact_sha256: digest, published: true, app_signature_verified: true, binary_path: "/app/cmux-tui", binary_sha256: digest, runtime_binaries: { "cmux-tui": { path: "/app/cmux-tui", sha256: digest } }, feed_url: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", artifact_url: "https://files-next.cmux.com/app.zip" });
const prefix = () => Array.from({ length: 300 }, (_, i) => ({ seq: i + 1, kind: "agent_message_chunk", msg: { text: `line ${i}`, extra: true } }));
const snapshot = () => ({ snapshot: 3, manifest: { harness: "claude", harnessSessionId: "native-id", lastSeq: 300, openTurn: { tool: { name: "Bash", args: "python3 silent.py" } }, queue: [], native: [{ label: "claude-project", chunks: ["chunk"] }] } });
const recovered = () => [
  { seq: 301, kind: "user_message", msg: { text: "The machine this chat ran on went away. Continue." } },
  { seq: 302, kind: "agent_message_chunk", msg: { params: { update: { content: { type: "text", text: "recovered nonce" } } } } },
  { seq: 303, kind: "turn_result", msg: { status: "completed" } },
];
describe("published NIGHTLY recovery evidence", () => {
  test("cleanup reconciles an ambiguous delete and never treats deleting as deleted", async () => {
    const states = ["running", "deleting", "deleted"];
    let deletes = 0;
    await confirmDeleted(async () => ({ status: states.shift()! }), async () => { deletes++; throw new Error("lost reply"); }, async () => {});
    expect(deletes).toBe(1);
    await expect(confirmDeleted(async () => ({ status: "deleting" }), async () => {}, async () => {})).rejects.toThrow("not terminal");
    await expect(confirmDeleted(async () => { throw new Error("read unavailable"); }, async () => { deletes++; }, async () => {})).rejects.toThrow("read unavailable");
    expect(deletes).toBe(1);
    await confirmDeleted(async () => null, async () => { deletes++; });
    expect(deletes).toBe(1);
  });
  test("requires both full sources, exact product ancestry and signed publication", () => {
    expect(validateProvenance(good()).source_sha).toBe(sha);
    for (const change of [{ source_sha: "main" }, { daemon_source_sha: "1234567" }, { contains_sha: sha }, { published: false }, { app_signature_verified: false }, { binary_sha256: "c".repeat(64) }, { runtime_binaries: {} }, { feed_url: "https://other.test/feed" }]) {
      expect(() => validateProvenance({ ...good(), ...change })).toThrow();
    }
  });
  test("binds companion bytes and rejects omitted or missing companions", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "recovery-receipt-"));
    try {
      const binary = path.join(dir, "cmux-tui"); writeFileSync(binary, "engine");
      const sum = createHash("sha256").update("engine").digest("hex");
      const receipt = validateProvenance({ ...good(), binary_path: binary, binary_sha256: sum, runtime_binaries: { "cmux-tui": { path: binary, sha256: sum } } });
      verifyRuntimeFiles(receipt, binary);
      writeFileSync(path.join(dir, "cmux-holder"), "holder");
      expect(() => verifyRuntimeFiles(receipt, binary)).toThrow("receipt missing");
      receipt.runtime_binaries["cmux-holder"] = { path: path.join(dir, "missing"), sha256: sum };
      expect(() => verifyRuntimeFiles(receipt, binary)).toThrow("companion missing");
      receipt.runtime_binaries["cmux-holder"].path = path.join(dir, "cmux-holder");
      expect(() => verifyRuntimeFiles(receipt, binary)).toThrow("companion changed");
    } finally { rmSync(dir, { recursive: true }); }
  });
  test("normalizes store wrappers and rejects malformed events", () => {
    expect(eventTuples([{ seq: 1, record: { kind: "user_message", msg: { text: "x" } } }])).toEqual([{ seq: 1, kind: "user_message", msg: { text: "x" } }]);
    for (const event of [{ seq: 0, kind: "x", msg: {} }, { seq: 1, kind: "x" }]) expect(() => eventTuples([event])).toThrow();
  });
  test("compares a complete multipage prefix, ignoring object key order only", () => {
    const a = prefix(), b = a.map(e => ({ ...e, msg: { extra: true, text: e.msg.text } }));
    expect(assertJournalPrefix(a, b, 300)).toHaveLength(64);
    for (const bad of [b.slice(1), [...b, b[299]], b.map((e, i) => i === 128 ? { ...e, msg: { extra: true, text: "altered" } } : e)]) expect(() => assertJournalPrefix(a, bad, 300)).toThrow();
    expect(() => assertJournalPrefix(a.slice(1), b, 300)).toThrow("source prefix");
    expect(() => assertJournalPrefix(a, b, 256)).toThrow("multiple event pages");
  });
  test("requires a renewed native snapshot of an open tool with no queued prompt", () => {
    expect(assertSnapshot(snapshot(), 2, "native-id").lastSeq).toBe(300);
    expect(() => assertSnapshot(snapshot(), 3, "native-id")).toThrow("advance");
    for (const change of [{ harnessSessionId: "other" }, { openTurn: null }, { queue: [{ prompt: "extra" }] }, { native: [] }, { lastSeq: 256 }]) {
      const value = snapshot(); Object.assign(value.manifest, change);
      expect(() => assertSnapshot(value, 2, "native-id")).toThrow();
    }
  });
  test("marker proves exactly one shell execution", () => {
    assertMarker("nonce\n", "nonce");
    for (const marker of ["", "nonce", "nonce\nnonce\n", "other\n"]) expect(() => assertMarker(marker, "nonce")).toThrow();
  });
  test("requires exactly one successful native continuation, with no replayed tool", () => {
    assertRecovered(recovered(), 300, "nonce");
    for (const events of [recovered().slice(1), [...recovered(), { seq: 304, kind: "user_message", msg: { text: "extra" } }], [...recovered(), { seq: 304, kind: "resume_failed", msg: {} }], [...recovered(), { seq: 304, kind: "tool_call", msg: {} }], recovered().slice(0, 2), recovered().map(e => e.kind === "turn_result" ? { ...e, msg: { status: "error" } } : e)]) expect(() => assertRecovered(events, 300, "nonce")).toThrow();
    expect(() => assertRecovered(recovered(), 300, "another-nonce")).toThrow("real agent");
  });
  test("follows all store pages and refuses stalls or gaps", async () => {
    const events = prefix(), calls: number[] = [];
    expect((await storeEvents(async after => { calls.push(after); return { lastSeq: 300, events: events.slice(after, after + 256) }; }, 0)).length).toBe(300);
    expect(calls).toEqual([0, 256]);
    await expect(storeEvents(async () => ({ lastSeq: 3, events: [] }), 0)).rejects.toThrow("no progress");
    await expect(storeEvents(async () => ({ lastSeq: 3, events: [events[1]] }), 0)).rejects.toThrow("gaps");
  });
  test("processes are parent-first and PID reuse is refused", () => {
    const root = { pid: 10, parent: 1, started: "now", command: "daemon" };
    const child = { pid: 2, parent: 10, started: "now", command: "holder" };
    const grandchild = { pid: 3, parent: 2, started: "now", command: "claude" };
    expect(descendants(10, [grandchild, child, root]).map(p => p.pid)).toEqual([10, 2, 3]);
    expect(sameProcess(root, { ...root })).toBe(true);
    expect(sameProcess(root, { ...root, started: "later" })).toBe(false);
    expect(sameProcess(root, { ...root, command: "other" })).toBe(false);
  });
  test("guest read script parses even with quoted input", () => {
    const script = guestReadProgram("session'quoted", "native", "marker").split("\n").slice(1, -1).join("\n");
    const result = spawnSync("python3", ["-c", "import ast,sys; ast.parse(sys.stdin.read())"], { input: script, encoding: "utf8" });
    expect(result.stderr).toBe(""); expect(result.status).toBe(0);
  });
  test("requires real Claude login without exposing it in failures", () => {
    const token = `sk-ant-oat01-${"x".repeat(20)}`;
    expect(claudeLoginFromEnv({ CLAUDE_CODE_OAUTH_TOKEN: ` ${token} ` })).toBe(token);
    expect(() => claudeLoginFromEnv({ CLAUDE_CODE_OAUTH_TOKEN: "bad-secret" })).toThrow("setup-token");
  });
  test("rejects invalid store wait cursors before any request", async () => {
    await expect(waitStore({ origin: "https://example.test", bearer: "bearer" }, "session", -1)).rejects.toThrow("non-negative integer");
  });
});
