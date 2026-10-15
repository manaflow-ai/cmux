// l10n-allow-file: gallery fixtures (sample chats and model names), not shipped UI.
// The composer's controls row (Composer.tsx, ComposerPickers.tsx, composerLocation.css)
// at the widths a chat pane takes (hq#1957 item 15): a left cluster (+, model, effort, the
// permission mode, 8 px apart) and a right cluster (mic, Send or Stop), with the row's free space only
// between the two; chips keep their full labels while the row has room, and a narrow pane drops
// the permission label first, then shortens effort, and the model last. These chats have started, so
// no location strip heads the card (locationRow.ts). test/composer-row-layout.test.ts measures it.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, CATALOG, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "./model";

const finished = [
  user("Add retries with backoff to the fetch helper", 10),
  assistant("Done: GETs retry, POSTs only with a policy.", 9),
  summary(9, { status: "completed" }),
];

const effort = {
  id: "effort",
  name: "Reasoning",
  category: "thought_level",
  currentValue: "medium",
  options: [
    { value: "low", name: "Low" },
    { value: "medium", name: "Medium" },
    { value: "high", name: "High" },
    { value: "xhigh", name: "Extra High" },
  ],
};

const fastMode = {
  id: "fast-mode",
  name: "Fast mode",
  category: "model_config",
  currentValue: "on",
  options: [
    { value: "off", name: "Off" },
    { value: "on", name: "On" },
  ],
};

const modes = {
  currentModeId: "auto",
  availableModes: [
    { id: "ask", name: "Supervised", description: "Ask before changing files or running commands" },
    { id: "edit", name: "Auto-accept edits", description: "Apply file edits without asking" },
    { id: "auto", name: "Auto", description: "Choose the safest approval level for each action" },
    { id: "bypassPermissions", name: "Full access", description: "Run actions without approval" },
  ],
};

// The chat in Leo's report: Claude Opus 5.5, Medium, Auto (no context ring: the model's tooltip says the usage).
function row(fields: Parameters<typeof chat>[1] = {}, extra: Partial<NonNullable<AcpmuxSnapshot["summary"]>> = {}) {
  const snapshot = chat(finished, { title: "Composer row", ...fields });
  return {
    ...snapshot,
    summary: { ...snapshot.summary!, configOptions: [effort], modes, ...extra },
  } satisfies AcpmuxSnapshot;
}

const LONG_MODEL = "claude-opus-5-5-1m";
const longCatalog = CATALOG.map((entry) =>
  entry.id === "claude"
    ? {
        ...entry,
        models: [
          {
            id: LONG_MODEL,
            name: "Opus 5.5 with a one-million-token context window",
            efforts: ["low", "medium", "high", "max"],
          },
          ...entry.models,
        ],
      }
    : entry,
);

// The model as the catalog names it in Leo's capture ("Claude Opus 5.5"; its short name is
// "Opus 5.5"), and a permission mode with a long label: the row the footer steps measure.
const leoCatalog = CATALOG.map((entry) =>
  entry.id === "claude"
    ? {
        ...entry,
        models: entry.models.map((model) =>
          model.id === "claude-opus-5-5" ? { ...model, name: "Claude Opus 5.5" } : model,
        ),
      }
    : entry,
);

export default agentPaneEntry({
  id: "agent-pane.composer-row",
  title: "Composer controls row",
  area: "Agent pane",
  height: 300,
  widths: { narrow: 420, normal: 720, wide: 1100 },
  anchors: [{ selector: ".acpmux-composer-bar" }, { selector: ".acpmux-composer-box" }],
  covers: ["agent-session/acpmux/Composer.tsx#Composer", "agent-session/acpmux/ComposerPickers.tsx#ComposerPickers"],
  variants: {
    "claude-auto": {
      note: "Claude Opus 5.5, Medium and Auto in one evenly spaced left cluster; mic and Send on the right.",
      snapshot: row(),
    },
    "long-model": {
      note: "A long model name: it shows whole while the row has room and is the last label to shorten.",
      snapshot: { ...row({ model: LONG_MODEL }), catalog: longCatalog },
    },
    "leo-report": {
      note: "Claude Opus 5.5 with Fast mode, Medium and Auto: a narrower pane swaps whole units (effort's short name, the model's family, its mark alone, then the mode's label and the mic), never an ellipsis; effort stays a chip of its own.",
      snapshot: {
        ...row({}, { configOptions: [effort, fastMode], modes }),
        catalog: leoCatalog,
      },
    },
    granted: {
      note: "A chat-wide allowance: the row still shows one lock, the mode's; the granted status gets no slot in it.",
      snapshot: {
        ...row(),
        permissionGroups: {
          supported: true,
          ready: true,
          busy: false,
          loading: false,
          chatAllowance: true,
          groups: [],
        },
      },
    },
    queued: {
      note: "A running turn with prompts queued above the field: Stop takes Send's circle, the row keeps its clusters.",
      snapshot: {
        ...row({ isWorking: true }),
        queue: [
          { id: "q1", prompt: "Then add a test for the 429 path" },
          { id: "q2", prompt: "And update the README" },
        ],
      },
    },
  },
});
