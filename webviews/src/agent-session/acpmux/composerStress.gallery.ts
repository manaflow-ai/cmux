// l10n-allow-file: gallery fixtures (sample chats, long names), not shipped UI.
// The composer under the objective edge cases (Leo 2026-11-23: "there is objectivity in design. we
// cannot miss these edge cases like this and let them languish"): panes of 280, 360 and 480 px,
// an empty draft, a draft of 200+ characters, one unbroken word, many attachments with long file
// names, long queued prompts, a long model name and mode, the slash and @ menus open, chat text at
// 200% (28 px, the font setting's maximum), short panes (140 and 200 px tall), and an attachment
// chip popping in under a draft (the box tracker fails any move of the controls or the prompt).
// Checks to read each shot against: controls keep their slot (bottom, never on a wrapped line),
// text gives way before controls (ellipsis), nothing overlaps or clips, no scrollbar at rest, the
// light and dark themes alike.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, CATALOG, chat, user } from "../../gallery/fixtures/acpmux";
import type { Play, PlayContext } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";

const finished = [user("Add retries with backoff to the fetch helper", 10), assistant("Done.", 9)];
const working = [user("Add retries with backoff to the fetch helper", 10)];

const effort = {
  id: "effort",
  name: "Reasoning",
  category: "thought_level",
  currentValue: "xhigh",
  options: [
    { value: "low", name: "Low" },
    { value: "medium", name: "Medium" },
    { value: "high", name: "High" },
    { value: "xhigh", name: "Extra High" },
  ],
};
const modes = {
  currentModeId: "long",
  availableModes: [
    { id: "ask", name: "Supervised", description: "Ask before changing files" },
    { id: "long", name: "Auto-accept edits and run safe commands", description: "A long mode name" },
  ],
};

const LONG_MODEL = "claude-opus-5-5-1m";
const longCatalog = CATALOG.map((entry) =>
  entry.id === "claude"
    ? {
        ...entry,
        models: [
          {
            id: LONG_MODEL,
            name: "Opus 5.5 with a one-million-token context window",
            efforts: ["low", "medium", "high", "xhigh"],
          },
          ...entry.models,
        ],
      }
    : entry,
);

function stress(
  rows = finished,
  fields: Parameters<typeof chat>[1] = {},
  extra: Partial<NonNullable<AcpmuxSnapshot["summary"]>> = {},
) {
  const snapshot = chat(rows, { title: "Composer stress", model: LONG_MODEL, ...fields });
  return {
    ...snapshot,
    catalog: longCatalog,
    summary: { ...snapshot.summary!, configOptions: [effort], modes, steering: true, ...extra },
  } satisfies AcpmuxSnapshot;
}

const SENTENCE = "Check composer wrapping and keep the first line, caret and controls in place as the prompt grows. ";
const LONG_DRAFT = SENTENCE.repeat(3);
const UNBROKEN = "https://example.com/" + "a-very-long-unbroken-path-segment".repeat(6);
const LONG_NAME = "Screenshot 2026-11-23 at 04.50.12 - the sidebar flickers when the pane is resized narrow.png";

/** Drops `count` screenshots with long names on the composer, in the strip view (a row at the top). */
const dropMany =
  (count: number): Play =>
  async (ctx: PlayContext) => {
    const view = ctx.document.defaultView!;
    view.cmuxAcpmuxComposer?.({ attachmentView: "strip" });
    const files = await Promise.all(
      Array.from({ length: count }, async (_, index) => {
        const canvas = ctx.document.createElement("canvas");
        canvas.width = 96;
        canvas.height = 96;
        const drawing = canvas.getContext("2d")!;
        drawing.fillStyle = `hsl(${(index * 47) % 360} 70% 60%)`;
        drawing.fillRect(0, 0, 96, 96);
        const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
        return new view.File([blob], `${index + 1} ${LONG_NAME}`, { type: "image/png" });
      }),
    );
    const drop = new view.Event("drop", { bubbles: true, cancelable: true });
    Object.defineProperty(drop, "dataTransfer", { value: { files, types: ["Files"] } });
    // The drop is the person's act: like a key that adds a line, it grows the composer (the strip
    // takes its row above the prompt), and layout/motionAudit.ts declares a drop's growth the same way.
    // The anchors still fail any move of the prompt box or the controls.
    const end = ctx.declare("composer-growth");
    try {
      ctx.find({ selector: ".acpmux-md" }).dispatchEvent(drop);
      await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-attachments .acpmux-attachment").length >= count);
    } finally {
      end();
    }
  };

/** The chat font setting at its maximum, 28 px: 200% of the 14 px default (chatDisplay.ts). */
const TEXT_200 = { "agentPane.display.font.size": 28 };

const queue = [
  {
    id: "q1",
    prompt:
      "Then add a test for the 429 path and make sure the backoff is jittered between each of the three tries. " +
      UNBROKEN,
  },
  { id: "q2", prompt: "And update the README" },
  { id: "q3", prompt: LONG_DRAFT },
];

export default agentPaneEntry({
  id: "agent-pane.composer-stress",
  title: "Composer stress: narrow panes, long names, many items",
  area: "Agent pane",
  height: 460,
  widths: { narrow: 280, normal: 360, wide: 480 },
  // The controls are an anchor too: a chip popping in above the prompt must not move them.
  anchors: [{ selector: ".acpmux-composer-box" }, { selector: ".acpmux-composer-actions" }],
  covers: ["agent-session/acpmux/Composer.tsx#Composer", "agent-session/acpmux/composerLocation.css"],
  variants: {
    empty: {
      composerLook: "claude",
      note: "Empty draft: the placeholder wraps or clips inside its slot, never under the controls.",
      snapshot: stress(),
    },
    "draft-200": {
      composerLook: "claude",
      note: "A 280-character draft wraps; the controls stay on the bottom row.",
      ready: { draft: LONG_DRAFT },
      snapshot: stress(),
    },
    "draft-unbroken": {
      composerLook: "claude",
      note: "One unbroken 200-character word: it breaks, never widens the box.",
      ready: { draft: UNBROKEN },
      snapshot: stress(),
    },
    "long-model-and-mode": {
      composerLook: "claude",
      note: "A long model name and mode label give way before the controls do.",
      snapshot: stress(),
    },
    "working-draft": {
      composerLook: "claude",
      note: "Running, with a draft: Stop and Send slot.",
      ready: { draft: LONG_DRAFT },
      snapshot: stress(working, { isWorking: true }),
    },
    "queued-long": {
      composerLook: "claude",
      note: "Three long queued prompts, one of them an unbroken word: each cuts with an ellipsis; actions keep their slot.",
      snapshot: stress(working, { isWorking: true, queue }),
    },
    "attachments-many": {
      composerLook: "claude",
      note: "Eight long-named screenshots in the top row: they scroll sideways; the prompt and controls stay put.",
      ready: { draft: "What do these show?" },
      snapshot: stress(),
      play: dropMany(8),
    },
    "attachments-one-long": {
      composerLook: "claude",
      note: "One screenshot with a very long file name.",
      ready: { draft: "What does this show?" },
      snapshot: stress(),
      play: dropMany(1),
    },
    "slash-menu": {
      composerLook: "claude",
      note: "The slash menu opens over the composer, inside the pane.",
      ready: { draft: "/" },
      snapshot: stress(),
    },
    "mention-menu": {
      composerLook: "claude",
      note: "The @ menu opens over the composer, inside the pane.",
      ready: { draft: "Look at @" },
      snapshot: stress(),
    },
    "text-200-empty": {
      composerLook: "claude",
      note: "Chat text at 200%: the placeholder and controls still fit one row's slot; nothing clips.",
      display: TEXT_200,
      snapshot: stress(),
    },
    "text-200-draft": {
      composerLook: "claude",
      note: "Chat text at 200% with a 280-character draft: it wraps and scrolls inside its cap; controls stay on the bottom row.",
      display: TEXT_200,
      ready: { draft: LONG_DRAFT },
      snapshot: stress(),
    },
    "text-200-working-queue": {
      composerLook: "claude",
      note: "Chat text at 200%, running, three long queued prompts: each still cuts with an ellipsis.",
      display: TEXT_200,
      snapshot: stress(working, { isWorking: true, queue }),
    },
    "text-200-slash-menu": {
      composerLook: "claude",
      note: "Chat text at 200% with the slash menu open: it stays inside the pane.",
      display: TEXT_200,
      ready: { draft: "/" },
      snapshot: stress(),
    },
    "short-200-draft": {
      composerLook: "claude",
      note: "A 200 px tall pane with a long draft: the composer caps below the pane's top, the controls stay in sight.",
      height: 200,
      ready: { draft: LONG_DRAFT },
      snapshot: stress(),
    },
    "short-140-empty": {
      composerLook: "claude",
      note: "A 140 px tall pane: the composer keeps its whole row; the transcript gives way.",
      height: 140,
      snapshot: stress(),
    },
    "short-200-attachments": {
      composerLook: "claude",
      note: "A 200 px tall pane, eight screenshots and a draft: strip, prompt and controls all stay in sight.",
      height: 200,
      ready: { draft: "What do these show?" },
      snapshot: stress(),
      play: dropMany(8),
    },
    "short-200-mention-menu": {
      composerLook: "claude",
      note: "A 200 px tall pane with the @ menu open: the menu fits in the pane, never off its top.",
      height: 200,
      ready: { draft: "Look at @" },
      snapshot: stress(),
    },
    "short-140-text-200": {
      composerLook: "claude",
      note: "Both at once: a 140 px tall pane and chat text at 200%, with a draft.",
      height: 140,
      display: TEXT_200,
      ready: { draft: LONG_DRAFT },
      snapshot: stress(),
    },
    "chip-pop-in": {
      composerLook: "claude",
      note: "One screenshot dropped under a two-line draft: its chip pops in above the prompt; the controls and prompt never move (box tracker).",
      ready: { draft: SENTENCE },
      snapshot: stress(),
      play: dropMany(1),
    },
    "chip-pop-in-text-200": {
      composerLook: "claude",
      note: "The same chip pop-in with chat text at 200%.",
      display: TEXT_200,
      ready: { draft: SENTENCE },
      snapshot: stress(),
      play: dropMany(1),
    },
  },
});
