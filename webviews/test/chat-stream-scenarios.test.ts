// l10n-allow-file: simulated chat fixtures for the chat simulator, not shipped UI.
// cmux-web-test-timeout: 300
// The chat pane's scenario map, run (docs/design/chat-stream-scenarios.md). Every `sim` scenario goes through the
// pane's reducer, turn view and layout on virtual time with the simulator's rules and the bubble-integrity rules;
// every `live` scenario goes through a connected client and a fake acpmux that duplicates, reorders, drops the
// socket or sends a summary; every `elsewhere` scenario names the test that holds it.
//
// A scenario that fails today and has an owner working on it is listed in KNOWN_RED with that owner: its test
// asserts it is still red (so a fix flips it, and the list must be updated), and the summary counts it.
// Leo, 2026-11-22: "there are probably more bullshit scenarios. we need to map them all out and note what
// expected behaviours are for all. idek."
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { connectClient, FakeDaemon, VirtualClock } from "../bench/stateGrowth";
import { turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { checkIntegrity, checkTextConserved, openSpans } from "../src/agent-session/acpmux/sim/integrity";
import { dedupe, messageIndex, runMapScenario, type MapFinding } from "../src/agent-session/acpmux/sim/mapRun";
import { SIM_SESSION } from "../src/agent-session/acpmux/sim/script";
import { STREAM_SCENARIOS, type LiveStep, type StreamScenario } from "../src/agent-session/acpmux/sim/streamScenarios";

/// Scenarios red today, each with its owner (streamScenarios.ts `owner`). Filled from the first CI run; a scenario
/// here that passes fails its test, so the list only shrinks as owners land fixes.
const KNOWN_RED: Record<string, string> = {
  // A Stop hook inside the harness (images/1157.png): live, the hook's line now draws between the two replies
  // (acpmux stop_hook_feedback). Once the turn ends, the default fold arm folds that line into Worked for with
  // the work, so the settled turn shows the two replies side by side again: the fold's own call (turns.ts).
  "SE-18": "turn-end fold keeps the hook line in sight (turns.ts foldSegments)",
  // feat-cmux-next's own chat-sim "incoming-notice-turn: rule b" is red on the base too: the same turn-end fold.
  "SE-22": "base: chat-sim incoming-notice-turn rule b (turn-end fold owner)",
};

let clock: VirtualClock | undefined;
afterEach(() => {
  clock?.uninstall();
  clock = undefined;
});

/// Plays a live scenario through a connected client: [] when every rule holds.
async function runLive(entry: StreamScenario): Promise<MapFinding[]> {
  const scenario = entry.live!.records();
  const events = scenario.events.map((event) => ({ ...event, sessionId: SIM_SESSION }));
  const steps: LiveStep[] = entry.live!.steps(events);
  clock = new VirtualClock().install();
  const daemon = new FakeDaemon();
  const session = daemon.add({
    sessionId: SIM_SESSION,
    cwd: "/home/dev/x",
    title: "sim",
    harness: "claude",
    status: "running",
    updatedAt: clock.now,
  });
  let { client, rows } = await connectClient(daemon, SIM_SESSION, clock);
  const findings: MapFinding[] = [];
  let sent = 0;
  let label = "open";
  let ended = false;
  const look = (step: number) => {
    const view = turnViewFrom(rows(), new Set<string>(), { working: !ended, agentFamily: "claude" });
    const seen = events.slice(0, sent);
    for (const finding of checkIntegrity({
      rows: view.rows,
      turnEnded: ended,
      messageOf: messageIndex(seen, client),
    }))
      if (!(entry.exempt ?? []).includes(finding.rule)) findings.push({ ...finding, step, label });
  };
  const deliver = async (event: EventRecord) => {
    if (!session.history.some((held) => held.seq === event.seq)) {
      session.history.push(event);
      session.history.sort((a, b) => a.seq - b.seq);
    }
    daemon.deliver(event);
    if (event.kind === "turn_result") ended = true;
    await clock!.advance(16);
  };
  for (const [index, step] of steps.entries()) {
    if ("push" in step) {
      for (; sent < Math.min(step.push, events.length); sent += 1) {
        label = events[sent]!.kind;
        await deliver(events[sent]!);
        look(index);
      }
    } else if ("duplicate" in step) {
      label = `duplicate ${events[step.duplicate]!.seq}`;
      daemon.deliver(events[step.duplicate]!);
      await clock.advance(16);
      look(index);
    } else if ("swap" in step) {
      const [a, b] = step.swap;
      label = `swap ${events[a]!.seq}<>${events[b]!.seq}`;
      // b first (it overtakes), then a; the daemon logs both in seq order.
      await deliver(events[b]!);
      look(index);
      await deliver(events[a]!);
      look(index);
      sent = Math.max(sent, b + 1);
      // Every record between them was skipped: deliver them now, after (late).
      for (let at = a + 1; at < b; at += 1) await deliver(events[at]!);
    } else if ("drop" in step) {
      label = "socket drop";
      daemon.drop();
      look(index);
    } else if ("summary" in step) {
      label = `summary ${JSON.stringify(step.summary)}`;
      daemon.changed({ ...session.summary, ...step.summary, sessionId: SIM_SESSION });
      await clock.advance(16);
      look(index);
    } else if ("advance" in step) {
      label = `advance ${step.advance}`;
      await clock.advance(step.advance);
      look(index);
    } else if ("reopen" in step) {
      label = "reopen";
      client.close();
      ({ client, rows } = await connectClient(daemon, SIM_SESSION, clock));
      look(index);
    }
  }
  await clock.advance(60_000);
  look(steps.length);
  for (const finding of checkTextConserved(events, rows()))
    findings.push({ ...finding, step: steps.length, label: "end" });
  client.close();
  clock.uninstall();
  clock = undefined;
  return dedupe(findings);
}

const results = new Map<string, MapFinding[]>();
const format = (findings: MapFinding[]) =>
  findings.slice(0, 6).map((finding) => `${finding.rule} @${finding.step} ${finding.label}: ${finding.detail}`);

describe("chat stream scenario map", () => {
  for (const entry of STREAM_SCENARIOS) {
    if (entry.harness === "elsewhere") continue;
    const red = KNOWN_RED[entry.id];
    test(`${entry.id} ${entry.title}${red ? ` (known red: ${red})` : ""}`, async () => {
      const findings = entry.harness === "sim" ? runMapScenario(entry) : await runLive(entry);
      results.set(entry.id, findings);
      if (red) expect(findings.length, `${entry.id} passes now: drop it from KNOWN_RED`).toBeGreaterThan(0);
      else expect(format(findings)).toEqual([]);
    });
  }

  test("every scenario has an id, an expectation, an owner and a way to run", () => {
    const ids = new Set<string>();
    for (const entry of STREAM_SCENARIOS) {
      expect(ids.has(entry.id), `duplicate id ${entry.id}`).toBe(false);
      ids.add(entry.id);
      expect(entry.expected.length).toBeGreaterThan(10);
      expect(entry.owner.length).toBeGreaterThan(3);
      if (entry.harness === "sim") expect(entry.make).toBeDefined();
      if (entry.harness === "live") expect(entry.live).toBeDefined();
      if (entry.harness === "elsewhere") expect(entry.heldBy).toBeDefined();
    }
    for (const id of Object.keys(KNOWN_RED)) expect(ids.has(id), `KNOWN_RED names unknown ${id}`).toBe(true);
  });

  test("the map doc lists every scenario id", () => {
    const doc = join(import.meta.dir, "..", "..", "docs", "design", "chat-stream-scenarios.md");
    if (!existsSync(doc)) return;
    const text = require("node:fs").readFileSync(doc, "utf8") as string;
    const missing = STREAM_SCENARIOS.filter(
      (entry) => !entry.id.startsWith("TM-") && !text.includes(`| ${entry.id} |`),
    ).map((entry) => entry.id);
    expect(missing).toEqual([]);
  });

  test("summary", () => {
    const run = STREAM_SCENARIOS.filter((entry) => entry.harness !== "elsewhere");
    const pass = run.filter((entry) => results.get(entry.id)?.length === 0).map((entry) => entry.id);
    const fail = run.filter((entry) => (results.get(entry.id)?.length ?? 0) > 0);
    const lines = [
      `chat-stream-scenarios: ${pass.length} pass, ${fail.length} fail of ${run.length} run (${STREAM_SCENARIOS.length - run.length} held elsewhere)`,
      ...fail.map((entry) => `FAIL ${entry.id} [${entry.owner}] ${format(results.get(entry.id)!)[0] ?? ""}`),
    ];
    console.log(lines.join("\n"));
    if (process.env.CHAT_SCENARIOS_OUT)
      writeFileSync(
        process.env.CHAT_SCENARIOS_OUT,
        JSON.stringify(
          Object.fromEntries(
            run.map((entry) => [entry.id, { owner: entry.owner, findings: results.get(entry.id) ?? null }]),
          ),
          null,
          1,
        ),
      );
  });
});

describe("bubble-integrity rules", () => {
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}) =>
    ({ id, version: 1, at: 0, kind, text, ...extra }) as never;
  test("a reply cut inside **bold** with a Worked for between is one reply drawn as two", () => {
    const rows = [
      row("u", "user", "ask"),
      row("a1", "assistant", "Two paths. **GUI pa"),
      row("w", "worked"),
      row("a2", "assistant", "ths:** includes forking."),
    ];
    const found = checkIntegrity({ rows, turnEnded: true });
    expect(found.map((finding) => finding.rule)).toContain("i-split-bubble");
    expect(found.map((finding) => finding.rule)).toContain("i-unclosed-markdown");
  });
  test("two rows of one message are flagged; two messages around a tool are not", () => {
    const rows = [
      row("u", "user", "ask"),
      row("a1", "assistant", "First."),
      row("w", "worked"),
      row("a2", "assistant", "Second."),
    ];
    expect(checkIntegrity({ rows, turnEnded: true, messageOf: () => "m1" }).map((f) => f.rule)).toEqual([
      "i-split-bubble",
    ]);
    const tool = [
      row("u", "user", "ask"),
      row("a1", "assistant", "First."),
      row("t", "activity"),
      row("a2", "assistant", "Second."),
    ];
    expect(checkIntegrity({ rows: tool, turnEnded: true, messageOf: () => "m1" })).toEqual([]);
  });
  test("a paragraph drawn twice in a turn is flagged", () => {
    const para = "The cause was turns that end while a reply streams, so the next chunk opened a new row.";
    const rows = [row("u", "user", "ask"), row("a1", "assistant", `${para}\n\n${para}`)];
    expect(checkIntegrity({ rows, turnEnded: true }).map((f) => f.rule)).toEqual(["i-repeated-paragraph"]);
  });
  test("an ended turn's typing row is flagged", () => {
    const rows = [row("u", "user", "ask"), row("a1", "assistant", "Done."), row("typing", "typing")];
    expect(checkIntegrity({ rows, turnEnded: true }).map((f) => f.rule)).toEqual(["i-placeholder-after-end"]);
    expect(checkIntegrity({ rows, turnEnded: false })).toEqual([]);
  });
  test("open spans ignore code", () => {
    expect(openSpans("use `**` for bold")).toEqual([]);
    expect(openSpans("```sh\nbun test")).toEqual(["```"]);
    expect(openSpans("$$x")).toEqual(["$$"]);
  });
});
