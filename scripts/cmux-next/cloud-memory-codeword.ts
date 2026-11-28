/**
 * The agent-memory codeword row (hq `plans/cloud/agent-memory-follows-user.md`, step 5 "Prove it"): the probe pushes a
 * user `CLAUDE.md` holding this run's codeword from a person's device home, starts a fresh Cloud chat, and the row
 * passes only when the reply names the codeword. Leo, 2026-11-05: "there might even be, like, a memory or agents on MD
 * instructions type thing ... or, like, a Durable Object-type thing that could help around that area."
 *
 * The device home is a folder this run makes, standing in for the person's Mac home: the push is the same
 * `cmux link memory push` the Mac runs, against the person's `AgentHome` at client-config's platform_origin. The run's
 * codeword is random, so a reply can name it only if the instructions reached the machine.
 */
import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

export const PUSH_STEP = "agent home: codeword pushed from the device home";
export const REPLY_STEP = "agent home: reply names the codeword";

/** A codeword no model guesses: two words and hex, e.g. `amber-heron-3f9c2a`. */
export function codeword(bytes: Buffer = randomBytes(5)): string {
  const a = ["amber", "cobalt", "ember", "jade", "onyx", "russet", "saffron", "teal"];
  const b = ["heron", "lynx", "marten", "osprey", "puffin", "quokka", "tapir", "wren"];
  return `${a[bytes[0]! % a.length]}-${b[bytes[1]! % b.length]}-${bytes.subarray(2).toString("hex")}`;
}

/** The user CLAUDE.md the probe pushes. */
export function instructions(word: string): string {
  return `# Instructions from the cmux agent-memory probe\n\nThis run's codeword is ${word}. When anyone asks for the run codeword, answer with it exactly.\n`;
}

/** The first prompt of the fresh chat: it names no codeword, so only the carried file can supply it. */
export const PROMPT = "What is the run codeword in your user instructions? Reply with only the codeword.";

/** Passes only when the reply carries the run's codeword as written. */
export function replyNamesCodeword(reply: string, word: string): { ok: boolean; detail: string } {
  const ok = reply.includes(word);
  return { ok, detail: ok ? `named ${word}` : `the reply does not name ${word}: ${reply.trim().slice(0, 200) || "(empty)"}` };
}

/** A device home holding only the user CLAUDE.md, and the push's record folder beside it. */
export function deviceHome(word: string, root = mkdtempSync(path.join(tmpdir(), "cmux-memory-codeword-"))): { home: string; record: string } {
  const home = path.join(root, "home");
  mkdirSync(path.join(home, ".claude"), { recursive: true, mode: 0o700 });
  writeFileSync(path.join(home, ".claude", "CLAUDE.md"), instructions(word), { mode: 0o600 });
  const record = path.join(root, "record");
  mkdirSync(record, { recursive: true, mode: 0o700 });
  return { home, record };
}

/** What `cmux link memory push` answered: accepted at a revision, or why not. */
export function pushDetail(code: number | null, stdout: string, stderr: string): { ok: boolean; detail: string } {
  const line = stdout.trim().split("\n").reverse().find((l) => l.startsWith("{"));
  let answer: any = null;
  try { answer = line ? JSON.parse(line) : null; } catch {}
  if (code === 0 && answer?.ok === true && Number.isInteger(answer?.accepted_revision)) {
    return { ok: true, detail: `accepted at revision ${answer.accepted_revision}` };
  }
  const why = answer ? JSON.stringify(answer).slice(0, 240) : (stderr.trim().split("\n").pop() ?? "").slice(0, 240);
  return { ok: false, detail: `push exit ${code}: ${why || "no answer"}${answer?.ok === true ? " (not accepted: a person's device push lands its own change)" : ""}` };
}

/** The push, as the person's device runs it: the person's cmux access token, the platform as the head. */
export function push(cmux: string, platform: string, token: string, home: string, record: string): { ok: boolean; detail: string } {
  const env = { ...process.env, CMUX_AGENT_HOME_TOKEN: token, HOME: home };
  delete (env as Record<string, string | undefined>).CMUX_AGENT_HOME_CAPABILITY;
  const r = spawnSync(cmux, ["link", "memory", "push", "--head", platform, "--home", home, "--record", record, "--device", "cloud journey probe"], { env, encoding: "utf8", timeout: 60_000 });
  return pushDetail(r.status, r.stdout ?? "", r.stderr ?? "");
}

/** The person's follow switch (cloud.agentMemory.follow): a machine pulls the head only for a person who follows it. */
export async function follow(platform: string, token: string, fetcher: typeof fetch = fetch): Promise<{ ok: boolean; detail: string }> {
  const r = await fetcher(new URL("/v1/agent-home/follow", platform), {
    method: "PUT", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ follow: true }), signal: AbortSignal.timeout(30_000),
  });
  const text = await r.text().catch(() => "");
  return { ok: r.ok, detail: r.ok ? "follow on" : `follow PUT ${r.status}: ${text.slice(0, 200) || "(empty)"}` };
}
