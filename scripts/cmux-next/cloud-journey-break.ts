/**
 * The journey's degenerate legs (`cloud-journey.ts --break LEGS`): what a person does that a happy path never does, each
 * on the journey's own machine after its first reply, each judged "works, or fails fast with words that say what to
 * do". Leo, 2026-11-19: "getting the sort of connectivity, reliability, ergonomics, whatever, all that down pat".
 *
 *   twin-create      a second machine created at the same instant as the journey's own, on the same account: both
 *                    must reach running (or the second be refused with a reason, e.g. a plan's machine cap), never hang
 *   empty-prompt     `acp send` with an empty prompt: refused at once with words, or a turn that ends
 *   huge-prompt      a 256 KiB prompt (written to a file on the machine, sent on stdin): a reply, or refused with words
 *   twin-turn        two new sessions on the machine started and sent a prompt at the same instant: both reply
 *   delete-mid-turn  the journey's delete sent while a turn runs: the delete answers and the machine leaves the list
 *
 * The pure judges are exported for cloud-journey-break.test.ts; the legs take the journey's own exec and API.
 */

export const BREAK_LEGS = ["twin-create", "empty-prompt", "huge-prompt", "twin-turn", "delete-mid-turn"] as const;
export type BreakLeg = (typeof BREAK_LEGS)[number];

/** `--break a,b` (or `all`) as legs; unknown names throw so a typo never reads as a pass. */
export function parseBreak(raw: string | undefined): Set<BreakLeg> {
  if (!raw) return new Set();
  const names = raw.split(",").map((s) => s.trim()).filter(Boolean);
  if (names.includes("all")) return new Set(BREAK_LEGS);
  const bad = names.filter((n) => !(BREAK_LEGS as readonly string[]).includes(n));
  if (bad.length) throw new Error(`--break ${bad.join(",")}: one of ${BREAK_LEGS.join(", ")} or all`);
  return new Set(names as BreakLeg[]);
}

/** A refusal a person can act on: it names the problem (empty, too large, a limit) or the next step. */
const SAYS_WHAT = /empty|no (?:prompt|text|message)|too (?:large|long|big)|limit|at most|exceed|max(?:imum)?|try|run |use |shorten|split/i;

/** How long a refusal may take before it counts as a hang that happens to end. */
export const REFUSE_WITHIN_MS = 10_000;

export type SendOutcome = { exit: number; said: string; ms: number };

/**
 * A degenerate send's verdict: refused fast with words (pass), refused silently or slowly (fail), or accepted (null:
 * the caller then needs the turn to end).
 */
export function judgeRefusal(o: SendOutcome): { ok: boolean; why: string } | null {
  if (o.exit === 0) return null;
  const said = o.said.trim().slice(-240);
  if (o.ms > REFUSE_WITHIN_MS) return { ok: false, why: `refused after ${o.ms} ms (over ${REFUSE_WITHIN_MS} ms): ${said || "no words"}` };
  if (!said) return { ok: false, why: `refused (exit ${o.exit}) in ${o.ms} ms with no words` };
  if (!SAYS_WHAT.test(said)) return { ok: false, why: `refused (exit ${o.exit}) in ${o.ms} ms with words that do not say what to do: ${said}` };
  return { ok: true, why: `refused in ${o.ms} ms: ${said}` };
}

/** The guest shell program that writes `bytes` of prompt text to `file` (no argv carries it) and sends it on stdin. */
export function hugeSendProgram(guest: string, session: string, file: string, bytes: number): string {
  const line = "Ignore this filler line; at the end, reply with one short sentence. ";
  return `${guest}yes ${shq(line)} | head -c ${Math.max(1, Math.floor(bytes))} > ${shq(file)}; ` +
    `s=$(date +%s%N); "$c" acp send --no-wait ${shq(session)} - < ${shq(file)} 2>&1; rc=$?; e=$(date +%s%N); ` +
    `rm -f ${shq(file)}; echo "@@exit $rc"; echo "@@ms $(( (e - s) / 1000000 ))"`;
}

/** An empty prompt sent on stdin, timed on the machine. */
export function emptySendProgram(guest: string, session: string): string {
  return `${guest}s=$(date +%s%N); printf '' | "$c" acp send --no-wait ${shq(session)} - 2>&1; rc=$?; e=$(date +%s%N); ` +
    `echo "@@exit $rc"; echo "@@ms $(( (e - s) / 1000000 ))"`;
}

/** A send program's output as an outcome. */
export function sendOutcome(stdout: string, fallbackMs: number): SendOutcome {
  const exit = Number(/@@exit (\d+)/.exec(stdout)?.[1] ?? 1);
  const ms = Number(/@@ms (\d+)/.exec(stdout)?.[1] ?? fallbackMs);
  const said = stdout.replace(/@@exit \d+\n?/, "").replace(/@@ms \d+\n?/, "").trim();
  return { exit, said, ms };
}

/** Two sessions started and sent a prompt at once, in one guest program, so the agent daemon sees them together. */
export function twinTurnProgram(guest: string, sessions: [string, string], agent: string, prompt: string): string {
  const one = (s: string) =>
    `( "$c" acp ensure ${shq(s)} -m ${shq(agent)} --json >/dev/null 2>&1 && printf '%s' ${shq(prompt)} | "$c" acp send --no-wait ${shq(s)} - >/dev/null 2>&1; echo "@@sent ${s} $?" ) &`;
  return `${guest}${one(sessions[0])} ${one(sessions[1])} wait`;
}

/** Which twin sessions the program said it started and sent (exit 0). */
export function twinSent(stdout: string, sessions: [string, string]): string[] {
  return sessions.filter((s) => new RegExp(`@@sent ${s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")} 0\\b`).test(stdout));
}

/** A twin create's verdict: both machines made, or the second refused with a reason (a cap), never a bare error. */
export function judgeTwinCreate(first: { ok: boolean; why: string }, second: { ok: boolean; why: string }): { ok: boolean; why: string } {
  if (!first.ok) return { ok: false, why: `the journey's own create failed beside a twin: ${first.why}` };
  if (second.ok) return { ok: true, why: `both made: ${second.why}` };
  if (/cap|limit|quota|too many|plan/i.test(second.why) && /\b(?:delete|upgrade|pause|archive|free|wait|try)\b/i.test(second.why)) {
    return { ok: true, why: `the twin was refused with a next step: ${second.why.slice(0, 200)}` };
  }
  return { ok: false, why: `the twin create failed with no next step: ${second.why.slice(0, 240)}` };
}

export function shq(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}
