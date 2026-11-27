// The open composer hat's list, as Leo asked on 2026-11-27 ("as for the hat, let's just restore it and
// add those strict improvements"): its agents first, then its commands, each group under its count;
// the most recently changed line on top of its group; identical lines folded into one with a ×N; and
// each line's specific part (what it waits on) kept while its generic part truncates.
// What needs the person still leads its group (trayAttention.ts), so the height cap never hides it.
import { subagentStatus } from "../summary/subagentStatusListModel";
import { asksPerson, needsPerson, type TrayCard } from "./trayAttention";
import type { TrayItem } from "./runningTray";

/// Which group a line sits in: the subagents and the chats it started, or everything else
/// backgrounded (commands, waits, monitors, silent turns), as the header's two groups count them.
export type HatGroup = "agents" | "commands";

export const hatGroupOf = (item: TrayItem): HatGroup =>
  item.kind === "command" || item.kind === "turn" ? "commands" : "agents";

/// One drawn line: its card, the identical lines folded into it (their keys, its own first), and the
/// group it opens, when it is its group's first line.
export type HatCard = TrayCard & {
  readonly same: readonly TrayItem[];
  readonly opens?: { readonly group: HatGroup; readonly count: number };
};

/// When a line last changed, if known: its end, else its start.
export const changedAt = (item: TrayItem): number | undefined => {
  if (item.kind === "agent") return item.agent.endedAt ?? item.agent.startedAt;
  if (item.kind === "command") return item.command.endedAt ?? item.command.startedAt;
  if (item.kind === "turn") return item.turn.startedAt;
  return undefined;
};

/// A top-level line and the nested lines under it: they move as one.
type Tree = { cards: TrayCard[]; urgent: boolean; at: number; index: number };

function trees(items: readonly TrayItem[], ended: boolean, waiting: ReadonlySet<string>, out: Tree[]) {
  for (const item of items) {
    const nested = item.kind === "agent" && item.depth > 0;
    const last = out.at(-1);
    if (nested && last) {
      last.cards.push({ item, finished: ended });
      last.urgent ||= needsPerson(item, waiting);
      const at = changedAt(item);
      if (at !== undefined && at > last.at) last.at = at;
      continue;
    }
    out.push({
      cards: [{ item, finished: ended }],
      urgent: needsPerson(item, waiting),
      at: changedAt(item) ?? Number.NEGATIVE_INFINITY,
      index: out.length,
    });
  }
}

/// The open list, grouped and folded. `sameKey` says when two lines read the same (their kind, their
/// words, their state): a lone line with no nested lines folds into the first that reads as it does.
/// One pass when the lists change, never per tick.
export function hatCards(
  items: readonly TrayItem[],
  finished: readonly TrayItem[],
  waiting: ReadonlySet<string>,
  sameKey: (item: TrayItem) => string,
): readonly HatCard[] {
  const live: Tree[] = [];
  trees(items, false, waiting, live);
  const done: Tree[] = [];
  trees(finished, true, waiting, done);
  const order = (list: Tree[]) =>
    [...list].sort((a, b) => Number(b.urgent) - Number(a.urgent) || b.at - a.at || a.index - b.index);
  const out: HatCard[] = [];
  for (const group of ["agents", "commands"] as const) {
    const mine = (tree: Tree) => hatGroupOf(tree.cards[0]!.item) === group;
    const groupTrees = [...order(live.filter(mine)), ...order(done.filter(mine))];
    const cards: { card: TrayCard; same: TrayItem[] }[] = [];
    const byKey = new Map<string, TrayItem[]>();
    for (const tree of groupTrees) {
      const lone = tree.cards.length === 1;
      const key = lone ? `${tree.cards[0]!.finished ? "done" : "live"}:${sameKey(tree.cards[0]!.item)}` : undefined;
      const into = key === undefined ? undefined : byKey.get(key);
      if (into) {
        into.push(tree.cards[0]!.item);
        continue;
      }
      for (const card of tree.cards) {
        const same = [card.item];
        if (key !== undefined) byKey.set(key, same);
        cards.push({ card, same });
      }
    }
    // The group's count is what it holds still running or waiting: what ended is not counted.
    const count = groupTrees.reduce((n, tree) => n + tree.cards.filter((card) => !card.finished).length, 0);
    cards.forEach(({ card, same }, index) =>
      out.push({ ...card, same, ...(index === 0 ? { opens: { group, count } } : {}) }),
    );
  }
  return out;
}

/// What a line waits on, when its words say: checks (CI), a merge, or a reply. Read from the command
/// as typed (a command's, or the shell call a subagent runs now); a subagent or a chat that waits on
/// the person waits on a reply.
export type HatWait = "ci" | "merge" | "reply";

const WAITS: readonly [HatWait, RegExp][] = [
  ["merge", /\b(?:gh pr merge|land-judge|cmux-gh land|merge[-_ ]queue|land(?:_handoff)?\b.*--match-head-commit)/i],
  ["ci", /\b(?:gh (?:pr checks|run watch)|ci[-_]wait|run[-_]wait|cmux-gh wait|cmux-ci (?:wait|test)|pr[-_]wait|github-ci-wait|checks? --watch)\b/i],
  ["reply", /\b(?:inbox[-_ ](?:read|wait)|team[-_]listen|acpmux wait|wait[-_ ]reply|await(?:s|ing)? (?:a )?reply)\b/i],
];

export function hatWaitOf(item: TrayItem, waiting: ReadonlySet<string>): HatWait | undefined {
  if (item.kind === "agent" && subagentStatus(item.agent, waiting) === "waiting") return "reply";
  if (item.kind === "session" && asksPerson(item.session)) return "reply";
  const text =
    item.kind === "command"
      ? `${item.command.command}\n${item.command.description ?? ""}`
      : item.kind === "agent" && item.agent.actionShell
        ? (item.agent.action ?? "")
        : "";
  if (!text) return undefined;
  for (const [wait, pattern] of WAITS) if (pattern.test(text)) return wait;
  return undefined;
}

/// A line's words split where its generic part ends ("tbd-leo: ", "Reviewer · "), so the generic part
/// truncates first and the specific part (what it does, what it waits on) stays. A line with no such
/// break is all specific.
export function splitSpecific(name: string): { lead?: string; rest: string } {
  for (const mark of [" · ", ": "]) {
    const at = name.lastIndexOf(mark);
    if (at > 0 && at + mark.length < name.length)
      return { lead: name.slice(0, at + mark.length), rest: name.slice(at + mark.length) };
  }
  return { rest: name };
}
