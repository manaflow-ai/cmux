// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A long streaming reply for the frame-budget test (test/streaming-text-frames.test.ts) and its
// gallery entry (streamingText.gallery.tsx): about 5,000 characters of Markdown with every block a
// long answer has, the chat history it follows, and when each delta arrives at Claude's cadence
// (16 characters every 50 ms) or Codex's (runs of tokens a few ms apart, then 100-500 ms pauses,
// from a seeded PRNG, so a run is the same every time).
import type { AcpmuxRow } from "../model";

/// A reply of about 5,000 characters with every block a long answer has.
export const REPLY = [
  "I read the retry path end to end, from the socket wrapper down to the queue that replays requests after a " +
    "reconnect. The short version is that every client waits the same fixed delay before it tries again, so when " +
    "the relay restarts, a few thousand of them come back in the same second and knock it over again. The fix is " +
    "small, but it touches three places, so here is what changes and why.",
  "",
  "I also looked at the last three incidents in the relay's dashboard. Each one starts the same way: a deploy " +
    "restarts the relay, the open sockets close within a few hundred milliseconds of each other, and the first " +
    "wave of reconnects arrives before the new process has finished loading its routing table. The relay answers " +
    "that wave with errors, every client schedules its next try for exactly the same moment, and the cycle repeats " +
    "until someone scales the relay up by hand.",
  "",
  "## What happens today",
  "",
  "- `RetryPolicy.next()` returns a fixed 500 ms delay for every attempt, with no cap on the attempt count.",
  "- The socket wrapper resets the attempt counter on **every** open, even one that closes again at once.",
  "- Queued requests replay in one burst as soon as the socket opens, before the relay has said it is ready.",
  "- Nothing records why a connection closed, so the logs cannot tell a restart from a network drop.",
  "- The health check shares the same policy, which means it hammers the relay just as hard as the clients.",
  "",
  "## The plan",
  "",
  "1. Replace the fixed delay with exponential backoff and full jitter.",
  "   - Start at 250 ms and double each attempt, capped at 30 seconds.",
  "   - Pick the actual delay uniformly between zero and that ceiling, so a crowd spreads out.",
  "2. Count an open as healthy only after the relay's `ready` frame arrives.",
  "   - A socket that opens and closes within two seconds keeps its attempt count.",
  "   - The counter resets once a request completes on the new connection.",
  "3. Drain the replay queue at a steady rate instead of all at once.",
  "   - Ten requests every 100 ms is plenty for the busiest workspace we measured.",
  "4. Log the close code and reason with each retry, so the next outage is easy to read.",
  "",
  "Here is the new policy. It keeps the same interface, so the call sites do not change:",
  "",
  "```ts",
  "export type RetryOptions = {",
  "  baseMs?: number;",
  "  capMs?: number;",
  "  random?: () => number;",
  "};",
  "",
  "export class RetryPolicy {",
  "  private attempt = 0;",
  "  private readonly baseMs: number;",
  "  private readonly capMs: number;",
  "  private readonly random: () => number;",
  "",
  "  constructor({ baseMs = 250, capMs = 30_000, random = Math.random }: RetryOptions = {}) {",
  "    this.baseMs = baseMs;",
  "    this.capMs = capMs;",
  "    this.random = random;",
  "  }",
  "",
  "  /** The delay before the next attempt: full jitter under an exponential ceiling. */",
  "  next(): number {",
  "    const ceiling = Math.min(this.capMs, this.baseMs * 2 ** this.attempt);",
  "    this.attempt += 1;",
  "    return Math.round(this.random() * ceiling);",
  "  }",
  "",
  "  /** A request completed on the new connection: start over. */",
  "  reset(): void {",
  "    this.attempt = 0;",
  "  }",
  "}",
  "```",
  "",
  "With the defaults, the ceilings and the spread look like this for the first eight attempts:",
  "",
  "| Attempt | Ceiling | Mean delay | Clients per second (of 5,000) |",
  "| --- | ---: | ---: | ---: |",
  "| 1 | 250 ms | 125 ms | 5,000 |",
  "| 2 | 500 ms | 250 ms | 5,000 |",
  "| 3 | 1 s | 500 ms | 5,000 |",
  "| 4 | 2 s | 1 s | 2,500 |",
  "| 5 | 4 s | 2 s | 1,250 |",
  "| 6 | 8 s | 4 s | 625 |",
  "| 7 | 16 s | 8 s | 313 |",
  "| 8 | 30 s | 15 s | 167 |",
  "",
  "By the fourth attempt the relay sees half the load it sees today, and by the sixth it is well under what it " +
    "handles in a normal minute. I have not changed the health check yet: it should get its own policy with a " +
    "longer base delay, and I would rather do that in a separate change once this one has run for a day. If you " +
    "want, I can also add a small test that drives the policy with a seeded random source and checks the " +
    "ceilings in the table above.",
  "",
  "## Rollout",
  "",
  "- Ship the policy behind the existing `relay.retry` setting, defaulting to the new schedule.",
  "- Watch the reconnect rate on the dashboard through the next two relay deploys.",
  "- If the first wave still errors, raise the base delay to 500 ms before touching anything else.",
  "",
  "Nothing here changes the wire protocol, so older clients keep working while the new ones roll out, and the " +
    "relay needs no change of its own. The one visible difference is that a client may now take up to thirty " +
    "seconds to come back after a long outage, which is the point: the relay comes back first.",
].join("\n");

/// The chat's history: enough turns to fill the view, so it opens at its latest line.
export function history(): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [];
  for (let turn = 0; turn < 7; turn += 1) {
    rows.push({ id: `h${turn}-user`, version: 1, at: turn * 10_000, kind: "user", text: `Question ${turn}?` });
    rows.push({
      id: `h${turn}-answer`,
      version: 1,
      at: turn * 10_000 + 1,
      kind: "assistant",
      text:
        `History answer ${turn}. The keeper climbed to the gallery and wiped the salt from the lantern glass, ` +
        "then watched the light sweep the water for a while before going back down to write the log.",
    });
    rows.push({
      id: `h${turn}-end`,
      version: 1,
      at: turn * 10_000 + 2,
      kind: "turnSummary",
      status: "completed",
      durationMs: 4_000,
    } as AcpmuxRow);
  }
  return rows;
}

export type Cadence = "claude" | "codex";
export type Delta = { at: number; text: string };

/// A small seeded PRNG (mulberry32), so a cadence is the same on every run.
function prng(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4_294_967_296;
  };
}

/// When each delta of `text` arrives, in ms from the first.
export function schedule(text: string, cadence: Cadence, seed = 7): Delta[] {
  const deltas: Delta[] = [];
  if (cadence === "claude") {
    for (let index = 0; index < text.length; index += 16)
      deltas.push({ at: (index / 16) * 50, text: text.slice(index, index + 16) });
    return deltas;
  }
  const random = prng(seed);
  const between = (low: number, high: number) => low + random() * (high - low);
  let at = 0;
  let index = 0;
  while (index < text.length) {
    const tokens = Math.round(between(8, 30));
    for (let token = 0; token < tokens && index < text.length; token += 1) {
      const size = Math.round(between(2, 8));
      deltas.push({ at, text: text.slice(index, index + size) });
      index += size;
      at += between(1, 6);
    }
    at += between(100, 500);
  }
  return deltas;
}
