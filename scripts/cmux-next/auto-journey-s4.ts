/**
 * S4 of the AutoCloud slice (cmuxterm-hq docs/cloud/autocloud-proof-plan.md): the phone reaches the chat on the Auto
 * machine while the Mac is asleep. auto-journey.ts runs it after the move to the Cloud with the Mac daemon stopped
 * (SIGSTOP, as a closed lid freezes it), so nothing the Mac would do can carry a message.
 *
 *   read   the phone's read (GET the chat, then its last event) shows holder `vm:` and the last event, within 5 s
 *   sends  N phone sends (POST inbox), one at a time; each is timed post -> answer, post -> inbox ack, and post -> the
 *          turn's answer from the machine (`side=vm`) in the store's events
 *   once   the first id posted again is the same message (the inbox count does not move), and every message ran once
 *
 * Its numbers (p50 and p99 of each leg) go in the journey's step detail and in OUT/s4.json, which the slice probe
 * reads. The store's routes are backend/apps/api/src/auto-sessions/routes.ts.
 */

export type S4View = { holder: string; version: number; lastSeq: number; inbox?: number; inboxAcked?: number };
export type S4Reply = { status: number; body: any };
export type S4Deps = {
  /** The owner's call to /v1/auto-sessions/<id><route>. */
  store: (method: string, route: string, body?: unknown, timeoutMs?: number) => Promise<S4Reply>;
  now: () => number;
  sleep: (ms: number) => Promise<void>;
  /** The machine's record of the turns it ran (the stand-in harness's line per turn), for the once check. Without it,
   * the check is the store's events: each send answered at least once. */
  ranOnMachine?: () => Promise<string>;
};
export type S4Leg = { p50: number; p99: number; max: number };
export type S4Result = {
  ok: boolean;
  why: string;
  n: number;
  readMs: number;
  post: S4Leg | null;
  ack: S4Leg | null;
  turn: S4Leg | null;
  samples: Array<{ id: string; postMs: number; ackMs: number; turnMs: number }>;
};

export const READ_BUDGET_MS = 5_000;
export const SEND_BUDGET_MS = 120_000;

/** Nearest-rank percentile of SAMPLES (ms), rounded to 0.1 ms. */
export function percentile(samples: number[], p: number): number {
  if (!samples.length) return NaN;
  const sorted = [...samples].sort((a, b) => a - b);
  const rank = Math.min(sorted.length, Math.max(1, Math.ceil((p / 100) * sorted.length)));
  return Math.round(sorted[rank - 1] * 10) / 10;
}

export const leg = (samples: number[]): S4Leg | null =>
  samples.length ? { p50: percentile(samples, 50), p99: percentile(samples, 99), max: percentile(samples, 100) } : null;

/** The prompt text of send I: unique, and never a substring of another send's (s4-1-end is not in s4-11-end). */
export const s4Text = (i: number) => `s4-${i}-end`;

/** How many of EVENTS are the machine's answer to TEXT (the stand-in harness answers `side=vm prompt=<text>`). */
export const vmAnswers = (events: Array<{ record: unknown }>, text: string): number =>
  events.filter((e) => JSON.stringify(e.record).includes(`side=vm prompt=${text}`)).length;

/** How many of the machine's turn lines (RAN_FILE) ran TEXT. */
export const ranLines = (ran: string, text: string): number =>
  ran.split("\n").filter((l) => l.includes(`side=vm prompt=${text}`)).length;

export const legText = (name: string, l: S4Leg | null) => (l ? `${name} p50 ${l.p50} p99 ${l.p99} ms` : `${name} -`);

export function s4Detail(r: S4Result): string {
  return `${r.ok ? "" : `${r.why}; `}n ${r.n}; read ${Math.round(r.readMs)} ms; ${legText("post", r.post)}; ${legText("ack", r.ack)}; ${legText("vm answer", r.turn)}`;
}

/** Runs S4 against chat ID held by `vm:MACHINE`. The caller has stopped the Mac daemon and starts it again after. */
export async function phoneSends(d: S4Deps, id: string, machine: string, tag: string, n: number): Promise<S4Result> {
  const chat = `/${encodeURIComponent(id)}`;
  const res: S4Result = { ok: false, why: "", n: 0, readMs: 0, post: null, ack: null, turn: null, samples: [] };
  const fail = (why: string) => {
    res.why = why;
    res.post = leg(res.samples.map((s) => s.postMs));
    res.ack = leg(res.samples.map((s) => s.ackMs));
    res.turn = leg(res.samples.map((s) => s.turnMs));
    return res;
  };
  const view = async (): Promise<S4View> => {
    const r = await d.store("GET", chat);
    if (r.status !== 200) throw new Error(`GET the chat: HTTP ${r.status}`);
    return r.body.session as S4View;
  };
  const eventsAfter = async (after: number): Promise<Array<{ seq: number; record: unknown }>> => {
    const all: Array<{ seq: number; record: unknown }> = [];
    for (;;) {
      const r = await d.store("GET", `${chat}/events?after=${after}`);
      if (r.status !== 200) throw new Error(`events: HTTP ${r.status}`);
      all.push(...r.body.events);
      if (!r.body.events.length || r.body.events.at(-1).seq >= r.body.lastSeq) return all;
      after = r.body.events.at(-1).seq;
    }
  };

  try {
    // The phone's read: who holds the chat, and its last event.
    const t0 = d.now();
    const v0 = await view();
    const last = v0.lastSeq > 0 ? await eventsAfter(v0.lastSeq - 1) : [];
    res.readMs = d.now() - t0;
    if (!v0.holder.startsWith(`vm:${machine}`)) return fail(`the phone reads holder ${v0.holder || "nobody"}, not vm:${machine}`);
    if (v0.lastSeq > 0 && last.at(-1)?.seq !== v0.lastSeq) return fail(`the phone's read has no event ${v0.lastSeq}`);
    if (res.readMs > READ_BUDGET_MS) return fail(`the phone's read took ${Math.round(res.readMs)} ms, over ${READ_BUDGET_MS}`);

    let seq = v0.lastSeq;
    let version = v0.version;
    for (let i = 1; i <= n; i++) {
      const msgId = `${tag}-s4-${i}`;
      const text = s4Text(i);
      const start = d.now();
      const posted = await d.store("POST", `${chat}/inbox`, { id: msgId, text });
      const postMs = d.now() - start;
      if (posted.status !== 200) return fail(`send ${i}: inbox HTTP ${posted.status} ${JSON.stringify(posted.body?.error ?? posted.body).slice(0, 160)}`);
      const number = Number(posted.body.session?.inbox ?? 0);
      if (i === 1) {
        const again = await d.store("POST", `${chat}/inbox`, { id: msgId, text });
        if (again.status !== 200 || Number(again.body.session?.inbox ?? 0) !== number) {
          return fail(`the same id posted twice was taken as two messages (inbox ${number} then ${again.body?.session?.inbox})`);
        }
      }
      let ackMs = NaN;
      let turnMs = NaN;
      const deadline = start + SEND_BUDGET_MS;
      while (Number.isNaN(ackMs) || Number.isNaN(turnMs)) {
        if (d.now() > deadline) return fail(`send ${i} (${msgId}): ${Number.isNaN(ackMs) ? "never acked" : "never answered side=vm"} in ${SEND_BUDGET_MS / 1000} s`);
        const w = await d.store("GET", `${chat}/wait?after=${version}&timeoutMs=20000`, undefined, 30_000);
        const v: S4View = w.status === 200 ? w.body.session : (await d.sleep(500), await view());
        version = Math.max(version, v.version);
        if (Number.isNaN(ackMs) && Number(v.inboxAcked ?? 0) >= number) ackMs = d.now() - start;
        if (Number.isNaN(turnMs) && v.lastSeq > seq) {
          const fresh = await eventsAfter(seq);
          if (vmAnswers(fresh, text) > 0) {
            turnMs = d.now() - start;
            seq = fresh.at(-1)?.seq ?? seq;
          }
        }
        if (!v.holder.startsWith(`vm:${machine}`)) return fail(`send ${i}: the holder became ${v.holder}`);
      }
      res.samples.push({ id: msgId, postMs, ackMs, turnMs });
      res.n = i;
    }

    // Once each: the machine ran every send exactly once (its own line per turn), else at least once in the events.
    const ran = d.ranOnMachine ? await d.ranOnMachine() : null;
    const all = ran === null ? await eventsAfter(v0.lastSeq) : [];
    for (let i = 1; i <= n; i++) {
      const c = ran === null ? vmAnswers(all, s4Text(i)) : ranLines(ran, s4Text(i));
      if (ran === null ? c < 1 : c !== 1) return fail(`send ${i} ran ${c} times on the machine, not once`);
    }
  } catch (e) {
    return fail(String((e as Error)?.message ?? e));
  }
  fail("");
  res.ok = true;
  return res;
}
