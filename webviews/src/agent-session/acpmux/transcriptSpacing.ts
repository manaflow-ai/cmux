// The transcript's settled spacing, measured against ChatGPT desktop, chatgpt.com, Claude Code
// desktop and claude.ai on 2026-11-02 (leo-workspace design/transcript-spacing.md, "The table").
// Leo, 2026-11-02, on our transcript: "ugh we'll really want to study how chatgpt desktop and claude
// desktop do their spacing i just feel gross looking at these" and "we need to like enforce the good
// versions when we find them later in the specs/comments/tests or something".
//
// One row per gap. test/transcript-spacing-table.test.ts draws gallery entry
// agent-pane.transcript-spacing-table and measures each row in Chromium, light and dark; a change to a
// value here is a change to the spec, in the same PR. Every distance is between visible marks, the
// way a screenshot measures it: a text line's centre (its glyph box's middle), a bubble's edge or an
// icon glyph's edge, so the font's line-height and our element nesting never move a number.
//
// `pending` names the PR that brings a gap to its value: until it lands the test expects that row to
// fail (bun `test.failing`), so the landing PR must drop `pending` and the row is enforced from then on.

export type SpacingRow = {
  /** The measurement's id, as the test names it. */
  id: string;
  /** What is measured, in words. */
  between: string;
  /** CSS px. */
  value: number;
  /** Allowed difference, CSS px. */
  tolerance: number;
  /** The references the value comes from (design/transcript-spacing.md has the images and methods). */
  source: string;
  /** The PR that brings this gap to `value`, while it has not landed. */
  pending?: string;
};

export const TRANSCRIPT_SPACING: readonly SpacingRow[] = [
  {
    id: "paragraph",
    between: "one paragraph's last line and the next paragraph's first line, centre to centre",
    value: 34.75,
    tolerance: 1,
    source: "our 22.75 line + grid inner gap 12; claude.ai 21 + 11.25, chatgpt.com 26 + 16",
  },
  {
    id: "prose-to-footer",
    between: "a reply's last line centre and its footer's first icon glyph centre",
    value: 35.375,
    tolerance: 1,
    source: "11.375 + 8 to a 32 button + 16; claude.ai 8 to its button, chatgpt.com 5",
    pending: "grid-system footer PR 1b (sizes and 8/24 rhythm, after #31609)",
  },
  {
    id: "footer-to-next",
    between: "the footer's glyph centre and the next row's centre (an inbox row)",
    value: 51,
    tolerance: 1,
    source: "16 + 24 + 11; claude.ai and Claude Code desktop 24 from the button row to the next block",
    pending: "grid-system footer PR 1b (sizes and 8/24 rhythm, after #31609)",
  },
  {
    id: "step-to-prompt",
    between: "a one-line row's centre and the next prompt bubble's top edge",
    value: 43,
    tolerance: 1,
    source: "11 + grid turn gap 32; Codex desktop ~16, Claude Code desktop ~24 after its action row",
  },
  {
    id: "prompt-to-step",
    between: "a prompt bubble's bottom edge and the centre of the one-line row under it",
    value: 51,
    tolerance: 1,
    source: "40 + 11; claude.ai 40 exact, Claude Code desktop 39 to 40, chatgpt.com 40",
    pending: "transcript spacing: room around runs and prompts",
  },
  {
    id: "step-to-prose",
    between: "a run's last row and the reply's first line, centre to centre",
    value: 38.375,
    tolerance: 1,
    source: "11 + 16 + 11.375; chatgpt.com 16 box gap, ChatGPT desktop and Claude Code desktop ~40 centre",
    pending: "transcript spacing: room around runs and prompts",
  },
  {
    id: "prose-to-step",
    between: "a reply's last line and the run under it, centre to centre",
    value: 38.375,
    tolerance: 1,
    source: "as step-to-prose (claude.ai 10 and 10, chatgpt.com 16 and 16: symmetric)",
    pending: "transcript spacing: room around runs and prompts",
  },
  {
    id: "step-pitch",
    between: "two consecutive one-line rows (tool runs, sent and received message lines, inbox rows), centre to centre",
    value: 22,
    tolerance: 0.5,
    source: "Claude Code desktop verbose rows 22; Codex desktop 26; chat-transcript.md one-line row pitch (#29965)",
  },
  {
    id: "run-to-step",
    between: "a run's last line and the one-line row under it (an inbox row), centre to centre",
    value: 22,
    tolerance: 0.5,
    source: "consecutive one-line rows sit flush, whether in one run or two rows",
  },
  {
    id: "step-to-live",
    between: 'a one-line row and the live line under it ("Sending message to …"), centre to centre',
    value: 22,
    tolerance: 0.5,
    source: "the live line is a one-line row",
  },
  {
    id: "live-to-step",
    between: 'the live line and the waiting group under it ("2 messages from 2 sessions"), centre to centre',
    value: 22,
    tolerance: 0.5,
    source: "the waiting group's head is a one-line row",
  },
];

/** The footer's icon buttons (design/transcript-spacing.md, "Reply footer"): ChatGPT's sizes (Leo:
 * "didn't i always say we can do it like chatgpt"), Claude's placement (the gaps above). */
export const FOOTER = {
  /** Icon glyph box, CSS px: chatgpt.com 20 (Claude 16). */
  glyph: 20,
  /** Button hit box: chatgpt.com 32 (Claude 24). */
  button: 32,
  /** Button to button, left edge to left edge: the buttons touch in both apps. */
  pitch: 32,
  pending: "grid-system footer PR 1b (sizes and 8/24 rhythm, after #31609)" as string | undefined,
} as const;

/** The person's prompt bubble (design/transcript-spacing.md, "Prompt bubble"). */
export const BUBBLE = {
  /** A one-line bubble's height, edge to edge: chatgpt.com 44, claude.ai and Claude Code desktop 45.
   * Its block padding is what our line leaves, (44 - line height) / 2, so the text sits as inset. */
  oneLine: 44,
  /** chatgpt.com and claude.ai 16. */
  paddingInline: 16,
  /** claude.ai and Claude Code desktop 12 (ChatGPT's 22 superellipse is a pill; Leo: no capsule pills). */
  radius: 12,
  pending: "transcript spacing: room around runs and prompts" as string | undefined,
} as const;
