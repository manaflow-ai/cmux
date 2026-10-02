// Text corpus for history and bots. All generators take an rng so history
// stays seeded while live traffic can use Math.random.

export type Rng = () => number;

export const pick = <T>(rng: Rng, xs: readonly T[]): T => xs[Math.floor(rng() * xs.length)];
export const randInt = (rng: Rng, lo: number, hi: number) => lo + Math.floor(rng() * (hi - lo + 1));

const SHORT = [
  "lol", "sure", "ok", "yep", "nope", "ty", "thanks!", "on it", "lgtm", "ship it", "nice", "wait what",
  "same", "+1", "brb", "back", "agreed", "hmm", "oh no", "haha", "good call", "will do", "done",
  "merged", "pushed", "rebasing", "one sec", "looking", "ah got it", "makes sense", "yeah", "ya",
  "fair", "interesting", "that's wild", "true", "gm", "gn", "omw", "k", "ooh", "classic", "rip",
  "can confirm", "not on my machine", "repro'd", "can't repro", "flaky?", "CI is red again",
];

const FILES = [
  "TerminalSurface.swift", "WorkspaceList.swift", "TabManager.swift", "GhosttyKit", "cmuxd", "the iroh lane",
  "SidebarView.swift", "the socket handler", "ConversationTranscript.swift", "reload.sh", "the pairing flow",
  "KeyboardShortcutSettings", "the PTY bridge", "the notification ring", "BrowserPanel.swift", "the release script",
];
const THINGS = [
  "scroll anchoring", "the keyboard seat", "reconnect backoff", "the replay buffer", "date separators",
  "tapback layout", "read receipts", "the typing indicator", "image sizing", "paging", "the composer",
  "focus restore", "split resize", "the debug socket", "the nightly", "push delivery", "the RC build",
];
const PEOPLE_REF = ["Lawrence", "Austin", "Leo", "Aziz", "John"];

const MEDIUM_TEMPLATES = [
  "just pushed a fix for {thing}, can someone sanity check?",
  "is anyone else seeing {thing} break after the last merge?",
  "I think {file} is the culprit, it never resets state on reconnect",
  "PR is up for {thing}: https://github.com/manaflow-ai/cmux/pull/{pr}",
  "nightly {ver} is out, includes the {thing} fix",
  "{person} do you have a sec to look at {file}?",
  "the repro is: open two workspaces, close the first, then {thing} goes sideways",
  "moving {thing} behind a flag until we know it's stable",
  "benchmarks look good, {thing} went from {a}ms to {b}ms",
  "heads up I'm refactoring {file} today, expect conflicts",
  "CI has been flaky on {file} all morning, rerunning",
  "I'll pair with {person} on {thing} after lunch",
  "does {file} own {thing} or does the view model?",
  "ok tagged build is ready, try the new {thing}",
  "filed https://github.com/manaflow-ai/cmux/issues/{pr} for {thing}",
  "can we cut an RC tonight? {thing} is the last blocker",
  "the dogfood build feels way snappier with the new {thing}",
  "lunch? thinking ramen",
  "anyone have the link to the {thing} design doc?",
  "reverting {pr}, it broke {thing} on Intel macs",
  "{thing} on iPad is still off by a few points",
  "I'm out tomorrow afternoon btw",
];

const LONG_PARAS = [
  "Okay so I dug into {thing} a bit more. The root issue is that {file} assumes the snapshot and the live stream share an ordering, but after a reconnect the replay can land before the snapshot finishes applying.",
  "My proposal: we make the server the single source of truth for ordering (monotonic seq), have the client keep a dedupe set keyed on event seq and message id, and treat anything older than the anchor as a page insert rather than a live append.",
  "That way scroll anchoring stays stable when older pages arrive, and we stop fighting the layout engine every time a burst comes in.",
  "I tested it against the sim with 7% history failures and a 2% duplicate rate and the transcript didn't jump once in about 20 minutes of scrolling.",
  "Downside is we need to rework {file} a bit, maybe a day of work. I'd rather do that than keep stacking timing patches.",
  "Also worth noting: {thing} regressed in {ver}, I bisected it to the change that moved layout into the background queue.",
  "For the record, here's what I tried:\n- bump the debounce\n- disable the animation\n- pin the anchor row\nnone of those fixed it fully.",
  "If nobody objects I'll start on this tomorrow morning and post a draft PR by EOD.",
  "Separately, the nightly crash rate dropped after {pr} landed, so thanks {person}!",
  "Thoughts? Happy to jump on a call if it's easier to talk through.",
];

const EMOJI = ["😂", "🔥", "🚀", "👀", "🙏", "💀", "✅", "🎉", "😅", "🤔", "❤️", "👍", "😭", "🫡", "⚡️", "🍜"];

const REPLY_TO_ME = [
  "yeah that makes sense", "hmm not sure, let me check", "oh nice!", "on it", "can you send the repro?",
  "lol same", "wait which build?", "I can take a look after this meeting", "agreed 100%",
  "pushing back a bit here, I think {file} should own that",
  "good catch, that's definitely a bug in {thing}",
  "I saw that too yesterday, thought it was just me",
  "ok merged",
];

function fill(rng: Rng, s: string): string {
  return s
    .replaceAll("{thing}", () => pick(rng, THINGS))
    .replaceAll("{file}", () => pick(rng, FILES))
    .replaceAll("{person}", () => pick(rng, PEOPLE_REF))
    .replaceAll("{pr}", () => String(randInt(rng, 9000, 15800)))
    .replaceAll("{ver}", () => `0.${randInt(rng, 60, 66)}.${randInt(rng, 0, 30)}`)
    .replaceAll("{a}", () => String(randInt(rng, 40, 400)))
    .replaceAll("{b}", () => String(randInt(rng, 3, 39)));
}

export function emojiOnly(rng: Rng): string {
  return Array.from({ length: randInt(rng, 1, 3) }, () => pick(rng, EMOJI)).join("");
}

export function longText(rng: Rng): string {
  const n = randInt(rng, 2, 4);
  const paras: string[] = [];
  for (let i = 0; i < n; i++) {
    const sentences = randInt(rng, 1, 2);
    paras.push(Array.from({ length: sentences }, () => fill(rng, pick(rng, LONG_PARAS))).join(" "));
  }
  return paras.join("\n\n");
}

/** Random chat message text. Distribution: 35% short, 45% medium, 8% long, 8% emoji-only, 4% medium+emoji. */
export function messageText(rng: Rng): string {
  const r = rng();
  if (r < 0.35) return pick(rng, SHORT);
  if (r < 0.8) return fill(rng, pick(rng, MEDIUM_TEMPLATES));
  if (r < 0.88) return longText(rng);
  if (r < 0.96) return emojiOnly(rng);
  return `${fill(rng, pick(rng, MEDIUM_TEMPLATES))} ${pick(rng, EMOJI)}`;
}

export function replyText(rng: Rng): string {
  const r = rng();
  if (r < 0.12) return longText(rng);
  if (r < 0.2) return emojiOnly(rng);
  return fill(rng, pick(rng, REPLY_TO_ME));
}

export function editedText(rng: Rng, text: string): string {
  const r = rng();
  if (r < 0.4) return `${text} (edit: nvm, fixed)`;
  if (r < 0.7) return `${text}\n\nactually scratch that, see the thread`;
  return fill(rng, pick(rng, MEDIUM_TEMPLATES));
}

const ASPECTS: [number, number][] = [
  [4032, 3024], [3024, 4032], [1920, 1080], [1080, 1920], [2048, 2048], [2560, 1600], [1170, 2532],
  [3000, 1000], [800, 2400], [640, 480], [1280, 720], [512, 512],
];

export function imageSize(rng: Rng): [number, number] {
  return pick(rng, ASPECTS);
}
