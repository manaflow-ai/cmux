// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The < n/m > between a prompt's versions (VersionSwitcher.tsx, branches.ts), as claude.ai draws it
// under an edited prompt (Leo, 2026-11-21: "if you fork or edit in claude you can simply click a left
// or right to go between the variations intra-chat"). A: the arrows in the footer row (what shipped
// before, cx-ncc.61); B (shipped): the same in a capsule; C: over the bubble; D: over the bubble in a capsule;
// E: an outlined capsule; F: a roomy one. The comparison sheets are /tmp/cao-sheets/fork-switcher/.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, session, summary, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../model";

const claude = (snapshot: AcpmuxSnapshot): AcpmuxSnapshot => ({
  ...snapshot,
  summary: snapshot.summary && { ...snapshot.summary, family: "claude" },
});

/// The open chat is version `index` (of 3) of the second prompt: its two siblings fork the same turn.
const edited = (index: 0 | 1 | 2): AcpmuxSnapshot => {
  const ids = ["parent", "fork-1", "fork-2"] as const;
  const open = ids[index];
  const base = claude(
    chat([
      user("Add retry with backoff to the uploader", 9, { id: "user-1", seq: 1 }),
      assistant("Done: three tries, doubling from 200 ms, only on 5xx and timeouts.", 8.5),
      summary(8.5, { id: "summary-1", seq: 4, status: "completed" }),
      user(
        [
          "Now cover it with a test that fakes two timeouts",
          "Now cover it with two tests",
          "Add a test, then a changelog line",
        ][index]!,
        6,
        { id: "user-5", seq: 5 },
      ),
      assistant(
        [
          "Added `uploader.retry.test.ts`; it passes and fails without the retry.",
          "Added two tests: one for the backoff, one for the 5xx-only rule.",
          "Added the test and a line under Unreleased.",
        ][index]!,
        5,
      ),
      summary(5, { id: "summary-5", seq: 8, status: "completed" }),
    ]),
  );
  return {
    ...base,
    sessionId: open,
    ...(index > 0 && { forkedAtSeq: 4 }),
    sessions: [
      session({ sessionId: "parent", title: "Uploader retry", turnCount: 2 }),
      session({ sessionId: "fork-1", title: "Uploader retry (edit 1)", parentId: "parent", forkSeq: 4, turnCount: 2 }),
      session({ sessionId: "fork-2", title: "Uploader retry (edit 2)", parentId: "parent", forkSeq: 4, turnCount: 2 }),
    ],
    summary: { ...base.summary!, sessionId: open },
  };
};

/// Hovers the edited prompt and checks the switcher drawn in the slot the look shows reads `count`.
const reads = (count: string, slot: "footer" | "head") => async (ctx: PlayContext) => {
  await ctx.hover({ text: /^Now cover|^Add a test/ });
  const shown = [...ctx.document.querySelectorAll<HTMLElement>(`.cv-user__versions[data-version-slot="${slot}"]`)].find(
    (el) => el.offsetParent !== null,
  );
  if (!shown) throw new Error(`no switcher in the ${slot} slot`);
  const text = shown.querySelector(".cv-user__version-count")?.textContent?.trim();
  if (text !== count) throw new Error(`expected ${count}, got ${text}`);
};

export default agentPaneEntry({
  id: "agent-pane.fork-switcher",
  title: "Version switcher",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/conversation/VersionSwitcher.tsx",
    "agent-session/acpmux/conversation/branches.ts",
    "agent-session/acpmux/conversation/UserBubble.tsx",
  ],
  anchors: [{ selector: ".acpmux-composer" }, { selector: ".acpmux-header" }],
  variants: {
    "a-footer": {
      note: "A, before (cx-ncc.61): the arrows in the row under the prompt, before its age and Copy. Small, and the count is a grey 28 px word among the row's glyphs.",
      snapshot: edited(1),
      documentAttributes: { "fork-switcher-look": "plain" },
      play: reads("2/3", "footer"),
    },
    "b-pill": {
      note: "B, shipped: the footer's arrows in a capsule with the count in full ink, so the three glyphs read as one control you can step. 84 by 24, the row's own height (A is 76 by 24), nothing moves when a prompt gains a version.",
      snapshot: edited(1),
      play: reads("2/3", "footer"),
    },
    "c-head": {
      note: "C: the arrows over the bubble's right edge, shown with the prompt instead of in the row under it; the footer keeps its age and Copy.",
      snapshot: edited(1),
      documentAttributes: { "fork-switcher-look": "head" },
      play: reads("2/3", "head"),
    },
    "d-head-pill": {
      note: "D: C in the capsule.",
      snapshot: edited(1),
      documentAttributes: { "fork-switcher-look": "head-pill" },
      play: reads("2/3", "head"),
    },
    "e-outline": {
      note: "E (round 2): the capsule as a hairline outline, no fill: quieter at rest, and it still reads as one control.",
      snapshot: edited(1),
      documentAttributes: { "fork-switcher-look": "outline" },
      play: reads("2/3", "footer"),
    },
    "f-roomy": {
      note: "F (round 2): B with a wider count and the arrows set apart: the biggest target, 12 px wider than B.",
      snapshot: edited(1),
      documentAttributes: { "fork-switcher-look": "roomy" },
      play: reads("2/3", "footer"),
    },
    "first-version": {
      note: "The first version: Previous is off, Next steps to the edit.",
      snapshot: edited(0),
      play: reads("1/3", "footer"),
    },
    "last-version": {
      note: "The last version: Next is off.",
      snapshot: edited(2),
      play: reads("3/3", "footer"),
    },
  },
});
