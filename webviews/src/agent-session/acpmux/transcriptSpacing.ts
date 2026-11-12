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
  },
  {
    id: "footer-to-next",
    between: "the footer's glyph centre and the next row's centre (an inbox row)",
    value: 51,
    tolerance: 1,
    source: "16 + 24 + 11; claude.ai and Claude Code desktop 24 from the button row to the next block",
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
    value: 43,
    tolerance: 1,
    source:
      '11 + grid turn gap 32: the prompt stays centred (Leo, 2026-11-01: "this is too close to tool calls, center it"; settled-spacing.json turn-gap). claude.ai and chatgpt.com draw 40, holding the bubble\'s own action row',
  },
  {
    id: "step-to-prose",
    between: "a run's last row and the reply's first line, centre to centre",
    value: 34.375,
    tolerance: 1,
    source:
      "11 + 12 + 11.375 (Lucas, 2026-11-11: 16 read as too much); chatgpt.com 16 box gap, ChatGPT desktop and Claude Code desktop ~40 centre",
  },
  {
    id: "prose-to-step",
    between: "a reply's last line and the run under it, centre to centre",
    value: 34.375,
    tolerance: 1,
    source: "as step-to-prose (claude.ai 10 and 10, chatgpt.com 16 and 16: symmetric)",
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
    id: "step-to-waiting",
    between: 'a one-line row and the waiting group under it ("2 messages from 2 sessions"), centre to centre',
    value: 22,
    tolerance: 0.5,
    source: "the waiting group's head is a one-line row",
  },
  {
    id: "step-to-live",
    between: 'the waiting group and the live line under it ("Sending message to …"), centre to centre',
    value: 34,
    tolerance: 0.5,
    source:
      '22 line + scaled run gap 12; Leo, 2026-11-04: "the gap between tool calls and thinking needs to be bigger"',
  },
];

/** Every other row kind of Leo's 2026-11-02 23:59Z capture (a received line, "Scheduled check", an
 * expanded "Ran 2 commands", "Compacting the conversation…"; Leo: "these are all so stupid looking" /
 * "the spacing" / "y'all need to just go study"), measured over gallery variant `all-kinds` by
 * test/transcript-spacing-kinds.test.ts. Targets and references: design/transcript-spacing.md, "Row
 * kinds". */
export const TRANSCRIPT_SPACING_KINDS: readonly SpacingRow[] = [
  {
    id: "body-line",
    between: "two wrapped lines of one paragraph, centre to centre",
    value: 22.75,
    tolerance: 0.5,
    source: "our 14 on 22.75 (holds); ChatGPT desktop, Codex desktop and chatgpt.com 24; Claude Code desktop ~15 on 20",
  },
  {
    id: "footer-to-received",
    between: "a reply footer's glyph centre and the received message line under it, centre to centre",
    value: 51,
    tolerance: 1,
    source: "as footer-to-next: 16 + 24 + 11; Claude 24 from the button row to the next block",
  },
  {
    id: "received-to-status",
    between: 'a received message line and the "Scheduled check" line under it, centre to centre',
    value: 22,
    tolerance: 0.5,
    source: "one-line rows sit flush (rule 3); no reference shows a received line over a scheduled check",
  },
  {
    id: "status-to-run",
    between: '"Scheduled check" and the "Ran 2 commands" line under it, centre to centre',
    value: 22,
    tolerance: 0.5,
    source: "one-line rows sit flush (rule 3)",
  },
  {
    id: "run-to-child",
    between: '"Ran 2 commands", opened, and its first command, centre to centre',
    value: 22,
    tolerance: 0.5,
    source:
      "our flush run (rule 3); Codex desktop 26.6 to its first command, Claude Code desktop 36.75 into its bordered card",
  },
  {
    id: "child-pitch",
    between: "an opened run's two commands, centre to centre",
    value: 22,
    tolerance: 0.5,
    source: "our one-line pitch (rule 3); Codex desktop 26, Claude Code desktop 34 (a card row with dividers)",
  },
  {
    id: "child-to-prose",
    between: "an opened run's last command and the reply under it, centre to centre",
    value: 34.375,
    tolerance: 1,
    source: "as step-to-prose: 11 + 12 + 11.375",
  },
  {
    id: "footer-to-prompt",
    between: "a reply footer's glyph centre and the next prompt bubble's top edge",
    value: 48,
    tolerance: 1,
    source:
      "16 + grid turn gap 32 (Leo's centring, settled-spacing turn-gap); Claude Code desktop 34.5, chatgpt.com 73 (16 + 57)",
  },
  {
    id: "prompt-to-status",
    between: "a prompt bubble's bottom edge and the compaction line under it, centre",
    value: 43,
    tolerance: 1,
    source: "as prompt-to-step: 32 + 11",
  },
  {
    id: "status-to-prose",
    between: "a finished compaction line and the reply under it, centre to centre",
    value: 34.375,
    tolerance: 1,
    source: "a status line keeps a run's 12 from prose (rule 4; Lucas, 2026-11-11)",
  },
  {
    id: "step-to-status",
    between: 'a one-line tool row and "Compacting the conversation…" under it, centre to centre',
    value: 22,
    tolerance: 0.5,
    source:
      "one-line rows sit flush (rule 3): notices are one-line rows; no reference shows a compaction line by a tool row",
  },
];

/** The status rows at the bottom of a running turn (design/transcript-spacing.md, "Row kinds", the
 * status rows; Leo, 2026-11-03 04:44Z, on two captures of a running Claude chat where they stood
 * 55 to 70 apart, then cramped: "this is pretty bad spacing and formatting" / "i thought we made this
 * stuff smaller"). Each is a one-line row: a run's last call, "Subagent finished", the live "Thinking"
 * line, the waiting group's "1 message from 1 session", another agent's received line and "Sent to".
 * Activity rows sit flush on the 22 pitch; the live line takes the run gap below activity. Measured over gallery
 * variants `working-bottom`, `reply-received`, `notes-live` and `status-prompt` by test/transcript-spacing-kinds.test.ts. */
export const TRANSCRIPT_STATUS_ROWS: readonly (SpacingRow & {
  variant: "working-bottom" | "reply-received" | "notes-live" | "status-prompt";
})[] = [
  {
    id: "work-to-subagent",
    variant: "working-bottom",
    between:
      'the running turn\'s last call ("Read src/turns.ts", its run in sight) and "Subagent finished" under it, centre to centre',
    value: 22,
    tolerance: 0.5,
    source: "one-line rows sit flush (rule 3)",
  },
  {
    id: "subagent-to-waiting",
    variant: "working-bottom",
    between: '"Subagent finished" and "1 message from 1 session" under it, centre to centre',
    value: 22,
    tolerance: 0.5,
    source: "the waiting group's head is a one-line row (rule 3, step-to-waiting)",
  },
  {
    id: "waiting-to-live",
    variant: "working-bottom",
    between: '"1 message from 1 session" and the live "Thinking" line under it, the turn\'s last, centre to centre',
    value: 34,
    tolerance: 0.5,
    source:
      '22 line + scaled run gap 12 (Lucas, 2026-11-11: 16 read as too much); Leo, 2026-11-04: "the gap between tool calls and thinking needs to be bigger"',
  },
  {
    id: "reply-footer-to-received",
    variant: "reply-received",
    between: "an earlier reply's footer glyph centre (hover-revealed) and the received line under it, centre to centre",
    value: 51,
    tolerance: 1,
    source: "as footer-to-received: 16 + 24 + 11",
  },
  {
    id: "received-to-sent",
    variant: "reply-received",
    between: 'another agent\'s received line and the "Sent to" line under it, centre to centre',
    value: 22,
    tolerance: 0.5,
    source: "one-line rows sit flush (rule 3)",
  },
  {
    id: "sent-to-live",
    variant: "reply-received",
    between: '"Sent to" and the live "Thinking" line under it, centre to centre',
    value: 34,
    tolerance: 0.5,
    source:
      '22 line + scaled run gap 12 (Lucas, 2026-11-11: 16 read as too much); Leo, 2026-11-04: "the gap between tool calls and thinking needs to be bigger"',
  },
  {
    id: "note-to-live",
    variant: "notes-live",
    between:
      'the last "Background task finished" note, after "Received 6 messages", and the live "Thinking" line under it, centre to centre',
    value: 34,
    tolerance: 0.5,
    source:
      '22 line + scaled run gap 12 (Lucas, 2026-11-11: 16 read as too much); Leo, 2026-11-04: "the gap between tool calls and thinking needs to be bigger"',
  },
  {
    id: "status-to-prompt",
    variant: "status-prompt",
    between: "a turn's last status row (\"Subagent finished\") and the next prompt bubble's top edge",
    value: 43,
    tolerance: 1,
    source: 'step-to-prompt: 11 + 32 (rule 5); Leo, 2026-11-03: "why is the spacing like this it\'s weird"',
  },
  {
    id: "prompt-to-sent",
    variant: "status-prompt",
    between: "a prompt bubble's bottom edge and the centre of its turn's first status row (\"Sent to …\")",
    value: 43,
    tolerance: 1,
    source: "prompt-to-step: 32 + 11 (rule 5)",
  },
];

/** A lone system line between turns, under the turn's footer row (design/transcript-spacing.md
 * "Lone system rows"; Leo, 2026-11-04, on a lone "Background update" a block gap under the footer and a
 * turn gap over the next prompt: "this bare background update tool call floating in teh air is so
 * weird loking proportionally"). The agent's own work that came in after the turn ended ("Background
 * update", "Background task finished", "3 background tasks finished", "Subagent finished") is that
 * turn's tail: 8 under the footer row, as the footer is under the reply, so its centre is as far from
 * the footer's glyph as the reply's last line is (prose-to-footer, 35.375); the next prompt keeps the
 * turn gap under it. Another agent's line there keeps footer-to-received. Measured over gallery entry
 * agent-pane.lone-system-rows by test/transcript-lone-system-rows.test.ts. */
export const LONE_SYSTEM_ROWS = {
  /** The footer's glyph centre to the line's centre: 16 + 8 + 11. */
  footerToLine: 35,
  /** The line's centre to the next prompt bubble's top edge: 11 + 32 (step-to-prompt). */
  lineToPrompt: 43,
  /** Another agent's line under the footer: footer-to-received. */
  footerToReceived: 51,
  tolerance: 1,
  variants: [
    "background-update",
    "background-update-running",
    "background-task",
    "background-tasks-run",
    "subagent-finished",
  ],
} as const;

/** A session link chip on a one-line row (a received line's sender, "Sent to"'s recipient): no taller
 * than the row's text, so the row reads as one line of words (Leo, 2026-11-03, on a bordered chip
 * taller than its row's text: "i thought we made this stuff smaller"). Claude Code desktop names the
 * sender inline, underlined, at the row's size; ChatGPT draws a name as plain text. Measured over
 * gallery variant `reply-received` by test/transcript-spacing-kinds.test.ts. */
export const SESSION_CHIP = {
  /** The chip's box over its label's glyph box, CSS px: at most this much taller (ours 1em + 4px,
   * 18 at 14px, about 1.5 over the glyphs; the 22 chip it replaces stood 5 over them). */
  overText: 3,
  /** The chip's label is the row's own size: its font size over the row's text's, CSS px. */
  fontDelta: 0,
  pending: undefined as string | undefined,
} as const;

/** An opened run's commands sit this far in from its head's text (design/transcript-spacing.md, "Row
 * kinds"): text left edge to text left edge. Ours and Codex desktop 0, the icon in the head's column;
 * Claude Code desktop +7 inside a bordered card. */
export const RUN_CHILD = {
  indent: 0,
  tolerance: 1,
  pending: undefined as string | undefined,
} as const;

/** The footer's icon buttons (design/transcript-spacing.md, "Reply footer"): Claude's sizes in
 * ChatGPT's 32 line (Leo, 2026-11-02, of ChatGPT's 20 in 32: "WHY ARE THESE SO BIG"), Claude's
 * placement (the gaps above). */
export const FOOTER = {
  /** Icon glyph box, CSS px: Claude 16 (chatgpt.com 20). */
  glyph: 16,
  /** Button hit box: Claude Code desktop's 24 (chatgpt.com 32; Leo, 2026-11-04, beside Claude's: "spaing bad"). */
  button: 24,
  /** Button to button, left edge to left edge: the buttons touch in both apps. */
  pitch: 24,
  pending: undefined as string | undefined,
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
  pending: undefined as string | undefined,
} as const;

/** Any two consecutive one-line rows, whatever their kind (design/transcript-spacing.md rule 3):
 * another agent's received line, a background turn's line ("Scheduled check"), a tool run and its
 * opened steps, a compaction ("Compacting the conversation…") and the other status rows sit flush,
 * 22 apart centre to centre, with no gap between them (Leo, 2026-11-02, on a Claude chat where
 * they stood a block apart: "these are all so stupid looking"). Measured by
 * test/transcript-system-rows.test.ts on gallery entry agent-pane.transcript-system-rows. */
export const SYSTEM_ROW_PITCH = 22;
