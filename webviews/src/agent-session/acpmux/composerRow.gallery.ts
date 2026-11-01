// l10n-allow-file: gallery fixtures (sample chats and model names), not shipped UI.
// The composer's controls row (Composer.tsx, ComposerPickers.tsx, composerLocation.css)
// at the widths a chat pane takes (hq#1957 item 15): the permission mode, then one model button
// ("Opus 5.5  Medium", Leo 2026-10-20) and the context ring; the box keeps +, the mic and Send or
// Stop. Labels stay whole while the row has room, and a narrow pane shortens the effort first, then
// the model's name, and drops the permission label. Fast mode is a checkbox row of the model
// button's menu, never a bolt in the row. These chats have started, so no location strip heads the
// card (locationRow.ts). test/composer-row-layout.test.ts measures it.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, CATALOG, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { Play } from "../../gallery/play";
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
    { id: "bypassPermissions", name: "Bypass permissions", description: "Run actions without approval" },
  ],
};

// The chat in Leo's report: Claude Opus 5.5, Medium, Auto (no context ring: the model's tooltip says the usage).
// Claude Code steers (acpmux `steering`), so a prompt typed mid-turn draws the ↵ control.
function row(fields: Parameters<typeof chat>[1] = {}, extra: Partial<NonNullable<AcpmuxSnapshot["summary"]>> = {}) {
  const snapshot = chat(finished, { title: "Composer row", ...fields });
  return {
    ...snapshot,
    summary: { ...snapshot.summary!, configOptions: [effort], modes, steering: true, ...extra },
  } satisfies AcpmuxSnapshot;
}

/// Fast mode as Claude Code offers it (off/on).
function speed(current: string) {
  return {
    id: "fast-mode",
    name: "Fast mode",
    category: "model_config",
    currentValue: current,
    options: [{ value: "off" }, { value: "on" }],
  };
}

/** Fast mode lives in the model button's menu (Leo 2026-10-20): the row draws no bolt, and the
 *  menu's Fast mode checkbox sends the pick through the real pane's native command boundary, then
 *  follows the confirmed option. The play leaves the menu open on the confirmed state. */
function toggleFast(current: "on" | "off"): Play {
  return async (ctx) => {
    type Message = { method?: string; params?: { configId?: string; value?: string } };
    const pane = ctx.document.defaultView as unknown as {
      webkit: { messageHandlers: { agentSession: { postMessage(message: Message): unknown } } };
      cmuxAcpmuxBridge: { receive(snapshot: AcpmuxSnapshot): void };
    };
    const handler = pane.webkit.messageHandlers.agentSession;
    const original = handler.postMessage;
    const picks: string[] = [];
    handler.postMessage = (message) => {
      if (message.method === "chat.effort" && message.params?.configId === "fast-mode" && message.params.value)
        picks.push(message.params.value);
      return original(message);
    };
    const button = { selector: ".acpmux-model .acpmux-picker-button" } as const;
    const fast = { selector: ".acpmux-quick-menu .acpmux-quick-fast" } as const;
    try {
      await ctx.waitFor(() => ctx.document.querySelector(button.selector));
      if (ctx.document.querySelector(".acpmux-fast")) throw new Error("the composer must draw no speed bolt");
      await ctx.click(button);
      await ctx.waitFor(() => ctx.document.querySelector(fast.selector));
      const checked = () => ctx.find(fast).getAttribute("aria-checked");
      if (checked() !== String(current === "on")) throw new Error("Fast mode's check must follow the session");
      const next = current === "on" ? "off" : "on";
      await ctx.click(fast);
      await ctx.waitFor(() => picks.length > 0);
      if (picks[0] !== next) throw new Error(`fast mode command: expected ${next}, received ${picks[0]}`);
      // As the app does, publish the session's confirmed option through the pane bridge.
      pane.cmuxAcpmuxBridge.receive(row({}, { configOptions: [effort, speed(next)] }));
      await ctx.waitFor(() => checked() === String(next === "on"));
    } finally {
      handler.postMessage = original;
    }
  };
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
  covers: [
    "agent-session/acpmux/Composer.tsx#Composer",
    "agent-session/acpmux/ComposerPickers.tsx#ComposerPickers",
    "agent-session/acpmux/QuickModelMenu.tsx#QuickModelMenu",
  ],
  variants: {
    "claude-auto": {
      note: "Auto on the left; one model button, Opus 5.5  Medium, then the context ring on the right; mic and Send in the box.",
      snapshot: row(),
    },
    "grid-running": {
      note: "Grid measurement: running with the steer / queue placeholder and no draft.",
      snapshot: row({ isWorking: true }),
    },
    "grid-draft": {
      note: "Grid measurement: a single plain text line and Send.",
      ready: { draft: "Check the grid lines" },
      snapshot: row(),
    },
    "long-model": {
      note: "A long model name: it shows whole while the row has room and is the last label to shorten.",
      snapshot: { ...row({ model: LONG_MODEL }), catalog: longCatalog },
    },
    "leo-report": {
      note: "Claude Opus 5.5 with Fast mode on, Medium and Auto: a narrower pane swaps whole units (effort's short name, the model's family, the mode's label, the model's mark alone), never an ellipsis; the effort stays inside the one model button and no bolt shows.",
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
    "fast-off": {
      note: "A model with fast mode, off: no bolt in the row; the model button's menu ends on an unchecked Fast mode row, and a click turns it on.",
      snapshot: row({}, { configOptions: [effort, speed("off")] }),
      play: toggleFast("off"),
    },
    "fast-on": {
      note: "Fast on: the button still reads Opus 5.5  Medium, with no Fast word; the menu's Fast mode row is checked, and a click turns it off.",
      snapshot: row({}, { configOptions: [effort, speed("on")] }),
      play: toggleFast("on"),
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
