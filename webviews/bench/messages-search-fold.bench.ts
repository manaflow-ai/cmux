/// <reference types="bun" />
// l10n-allow-file: bench output labels, not shipped UI.

/**
 * Model-only bench for Messages' two searches as one keystroke runs them:
 *
 * - `list_search`: `listModel` with a query over CONVERSATIONS conversations (title, preview and member
 *   names are folded: case, width and accents aside).
 * - `recipients`: `suggestRecipients` over CONTACTS contacts for a short and a longer typed text.
 *
 * It prints p50/p95 ms per call over PASSES passes and `normalize_calls`, the folds one call makes (it
 * counts String.prototype.normalize, which every fold runs once). Run it on the base commit and on the
 * change, in one job on one machine, for the before/after:
 *
 *   bun bench/messages-search-fold.bench.ts
 *   CONVERSATIONS=2000 CONTACTS=5000 PASSES=40 bun bench/messages-search-fold.bench.ts
 *
 * Bun runs JavaScriptCore, the engine of the macOS and iOS web views. No React, DOM or frame claim.
 */
import type { HomeConversation, HomeParticipant } from "../src/pages/home-channels/types";
import { listModel, type ListWords } from "../src/pages/home-messages/list/model";
import { suggestRecipients, type HomeContact } from "../src/pages/home-messages/sheets/recipients";

const count = (name: string, fallback: number) => {
  const value = Number(process.env[name] ?? fallback);
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`${name} must be a positive integer`);
  return value;
};
const conversations = count("CONVERSATIONS", 2_000);
const contacts = count("CONTACTS", 5_000);
const passes = count("PASSES", 40);

// Seeded names with accents, so folding does real work.
let seed = 7;
const random = () => (seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648) / 2_147_483_648;
const first = ["Zoë", "José", "Ana", "Björn", "Chloé", "Renée", "Mark", "Siân", "Łukasz", "Amélie", "Noah", "Iñaki"];
const last = ["Müller", "García", "Nguyễn", "Øster", "Dvořák", "Smith", "Brontë", "Çelik", "Kowalski", "Leclère"];
const pick = <T>(list: readonly T[]) => list[Math.floor(random() * list.length)]!;
const person = () => `${pick(first)} ${pick(last)}`;

const now = Date.UTC(2026, 10, 21, 12, 0);
const map = new Map<string, HomeConversation>();
for (let index = 0; index < conversations; index += 1) {
  const participants: HomeParticipant[] = [
    { id: "me", kind: "human", name: "Me", chief: false },
    ...Array.from({ length: 1 + (index % 4) }, (_, at) => ({
      id: `p${index}-${at}`,
      kind: "human" as const,
      name: person(),
      chief: false,
    })),
  ];
  const conversation = {
    id: `c${index}`,
    owner: "local",
    title: index % 3 === 0 ? `Équipe ${pick(last)} ${index}` : "",
    kind: participants.length > 2 ? "group" : "direct",
    participants,
    lastSeq: index,
    rev: 1,
    updatedAt: now - index * 60_000,
    unread: index % 5,
    mentions: 0,
    muted: false,
    pinned: index < 8,
    lastText: `Café notes from ${person()}: the déjà vu build passed after ${index} tries`,
    lastAt: now - index * 60_000,
  } as HomeConversation;
  map.set(conversation.id, conversation);
}
const words: ListWords = {
  untitled: "Conversation",
  yesterday: "Yesterday",
  channel: "Channel",
  mentioned: "Mentioned",
  unread: (n) => `${n} unread`,
};
const people: HomeContact[] = Array.from({ length: contacts }, (_, index) => ({
  id: `u${index}`,
  name: person(),
  source: index % 10 === 0 ? "agent" : "team",
})) as HomeContact[];

const workloads: Record<string, () => unknown> = {
  list_search_short: () => listModel(map, { me: "me", query: "a", now, language: "en-US", words }),
  list_search_word: () => listModel(map, { me: "me", query: "garcia", now, language: "en-US", words }),
  recipients_short: () => suggestRecipients({ tokens: [], query: "a" }, people),
  recipients_word: () => suggestRecipients({ tokens: [], query: "muller" }, people),
};

const normalize = String.prototype.normalize;
let normalizeCalls = 0;
String.prototype.normalize = function (this: string, form?: string) {
  normalizeCalls += 1;
  return normalize.call(this, form);
};

const percentile = (sorted: number[], p: number) => sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]!;
const results: Record<string, { p50_ms: number; p95_ms: number; normalize_calls: number }> = {};
for (const [name, run] of Object.entries(workloads)) {
  for (let warm = 0; warm < 5; warm += 1) run();
  normalizeCalls = 0;
  run();
  const calls = normalizeCalls;
  const times: number[] = [];
  for (let pass = 0; pass < passes; pass += 1) {
    const start = performance.now();
    run();
    times.push(performance.now() - start);
  }
  times.sort((a, b) => a - b);
  results[name] = {
    p50_ms: Number(percentile(times, 0.5).toFixed(3)),
    p95_ms: Number(percentile(times, 0.95).toFixed(3)),
    normalize_calls: calls,
  };
}
String.prototype.normalize = normalize;
console.log(JSON.stringify({ conversations, contacts, passes, results }));
