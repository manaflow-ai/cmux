// l10n-allow-file: gallery fixtures exercise picker states and labels, not shipped copy.
import { useEffect, useMemo, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { ComposerPickers } from "./ComposerPickers";
import type { AcpmuxSnapshot } from "./model";
import { BUNDLED_MODEL_CATALOG, buildPickerCatalog } from "./modelCatalogData";
import { rememberStartMode, type StartMode } from "./startMode";

// Leo 2026-11-22: "the permission picker having a default of "mode" is so weird. it should be Auto
// to start. plain and simple. and opus 5.5 should have medium selected at baseline in the new chat
// area. it shouldnt just show plain opus 5.5 if it's going to go to medium by default. ... likewise
// with mode. dont make it show mode if auto is the default. the same goes for codexes."
//
// A new chat before its first send: no session, so the Mode chip names acpmux's `_acpmux/start_mode`
// answer and the model chip names the harness row's `start` model and effort (`_acpmux/harnesses`).
// acpmux's answer always names the mode the chat really runs in, the harness's own one too (Claude
// Code's Auto at the Harness Default level), so no variant here draws the bare word Mode.

type CatalogRow = AcpmuxSnapshot["catalog"][number];

type Props = {
  /// The harness row acpmux lists for this chat's harness.
  row: CatalogRow;
  /// acpmux's start-mode answer for it; none for a harness with no modes.
  answer?: StartMode;
  /// Each variant has its own folder: start-mode answers are kept per harness and folder, so one
  /// variant's answer never stands in for another's.
  folder: string;
};

const CLAUDE_MODELS = [
  { id: "default", name: "Default (recommended)" },
  { id: "claude-opus-5-5", name: "Opus 5.5" },
  { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
  { id: "claude-fable-5-1", name: "Fable 5.1" },
];

const claude = (start: CatalogRow["start"]): CatalogRow => ({
  id: "claude",
  name: "Claude Code",
  family: "claude",
  reportsModes: true,
  models: CLAUDE_MODELS,
  start,
});

const codex: CatalogRow = {
  id: "codex",
  name: "Codex",
  family: "codex",
  reportsModes: true,
  models: [
    { id: "gpt-6.2-sol", name: "GPT-6.2 Sol" },
    { id: "gpt-6.1-sol", name: "GPT-6.1 Sol" },
  ],
  start: { model: "gpt-6.2-sol", effort: "high", modelSource: "catalog", effortSource: "catalog" },
};

/// A second Claude Code account's profile that passes its own model to Claude Code: acpmux names no
/// start model for it, only the effort it starts on.
const profile: CatalogRow = {
  id: "claude-work",
  name: "Claude (work)",
  family: "claude",
  reportsModes: true,
  models: CLAUDE_MODELS,
  start: { effort: "medium", effortSource: "profile" },
};

/// Pi: its ACP modes only copy its thinking levels, so acpmux lists it with no permission modes.
const pi: CatalogRow = {
  id: "pi",
  name: "Pi",
  family: "pi",
  modeless: true,
  models: [{ id: "anthropic/claude-sonnet-5-5", name: "Claude Sonnet 5.5" }],
};

const OPUS_MEDIUM: CatalogRow["start"] = {
  model: "claude-opus-5-5",
  effort: "medium",
  modelSource: "catalog",
  effortSource: "catalog",
};

function GalleryInitialState({ row, answer, folder }: Props) {
  // As acpmux's answer would land before the chip draws (a kept answer draws on the first frame).
  const [answered, setAnswered] = useState(false);
  useEffect(() => {
    rememberStartMode(row.id, folder, answer);
    setAnswered(true);
  }, [row.id, folder, answer]);
  const snapshot = useMemo<AcpmuxSnapshot>(
    () => ({
      type: "snapshot",
      protocolVersion: 1,
      rows: [],
      sessions: [],
      connection: "gallery",
      isWorking: false,
      queue: [],
      canLoadOlder: false,
      origin: "local",
      catalog: [row],
      summary: { sessionId: "", harness: row.id, turnCount: 0, cwd: folder },
    }),
    [row, folder],
  );
  // The model catalog's join, as the agent pane builds it.
  const pickerCatalog = useMemo(
    () =>
      buildPickerCatalog({
        catalog: BUNDLED_MODEL_CATALOG,
        user: undefined,
        acpmux: snapshot.catalog,
        session: { harness: row.id },
      }),
    [snapshot, row.id],
  );
  return (
    <div className="acpmux-composer-gallery-shell">
      <div className="acpmux-composer-gallery-copy">
        <strong>New chat on {row.name}</strong>
        <span>Before the first send: the chips name the mode and effort the chat starts on.</span>
      </div>
      {answered && (
        <ComposerPickers
          snapshot={snapshot}
          pickerCatalog={pickerCatalog}
          harnessesListed
          folder={folder}
          onModel={() => undefined}
          onMode={() => undefined}
          onEffort={() => undefined}
          showPlan
        />
      )}
    </div>
  );
}

type Ctx = Parameters<Play>[0];

const text = (ctx: Ctx, selector: string) => ctx.document.querySelector(selector)?.textContent?.trim();
const MODE_TEXT = ".acpmux-mode .acpmux-mode-text";
const MODEL_NAME = ".acpmux-model-name";
const EFFORT_TEXT = '.acpmux-model-detail[data-fit-part="effort"]:not(.acpmux-fit-label)';

/// Waits for the composer's chips, then checks what they read. The pending Mode chip is aria-hidden
/// (it is the session's chip's placeholder) and the live one is named "Mode" for screen readers
/// whatever mode it shows, so the chip's visible text is what is read, not a button's name.
function expectChips({ mode, model, effort }: { mode?: string | null; model?: string; effort?: string }): Play {
  return async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(MODEL_NAME) !== null);
    if (mode === null) {
      if (ctx.document.querySelector(".acpmux-mode"))
        throw new Error(`a harness with no modes draws a Mode chip reading ${text(ctx, MODE_TEXT)}`);
    } else {
      await ctx.waitFor(() => !!text(ctx, MODE_TEXT));
      const shown = text(ctx, MODE_TEXT);
      if (shown === "Mode") throw new Error("the Mode chip reads the bare word Mode, not the mode the chat starts in");
      if (mode !== undefined && shown !== mode) throw new Error(`the Mode chip reads ${shown}, not ${mode}`);
    }
    const name = text(ctx, MODEL_NAME);
    if (!name || name === "Model") throw new Error(`the model chip names no model (${name ?? "nothing"})`);
    if (model !== undefined && name !== model) throw new Error(`the model chip reads ${name}, not ${model}`);
    if (effort !== undefined) {
      await ctx.waitFor(() => !!text(ctx, EFFORT_TEXT));
      const level = text(ctx, EFFORT_TEXT);
      if (level !== effort) throw new Error(`the model chip names ${level} after the model, not ${effort}`);
    }
  };
}

export default componentEntry<Props>({
  id: "agent-pane.composer-initial-state",
  title: "New chat composer: starting mode and effort",
  area: "Agent pane",
  pane: true,
  height: 260,
  // Keep the narrow stage below the model picker's 407px column-layout breakpoint.
  widths: { narrow: 400, normal: 640, wide: 860 },
  anchors: [{ selector: ".acpmux-chips" }],
  covers: ["agent-session/acpmux/ComposerPickers.tsx#ComposerPickers"],
  load: async () => GalleryInitialState,
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./composerControls.css"),
      import("./modelPicker.css"),
      import("./ComposerPickers.gallery.css"),
    ]),
  variants: {
    "claude-unset": {
      note: "Claude Code with nothing set: acpmux starts it at full access, so the Mode chip reads Bypass permissions.",
      props: {
        row: claude(OPUS_MEDIUM),
        answer: { modeId: "bypassPermissions", name: "Bypass permissions" },
        folder: "/Users/gallery/initial-claude-unset",
      },
      play: expectChips({ mode: "Bypass permissions" }),
    },
    "claude-harness-default": {
      note: "Claude Code at the Harness Default level: cmux sets no mode and Claude Code runs its own, Auto. The chip reads Auto, never Mode.",
      props: {
        row: claude(OPUS_MEDIUM),
        answer: { modeId: "auto", name: "Auto" },
        folder: "/Users/gallery/initial-claude-harness",
      },
      play: expectChips({ mode: "Auto" }),
    },
    "codex-unset": {
      note: "Codex with nothing set: acpmux starts it at full access, so the chip reads Full access, and the model chip names GPT-6.2 Sol High.",
      props: {
        row: codex,
        answer: { modeId: "agent-full-access", name: "Full access" },
        folder: "/Users/gallery/initial-codex-unset",
      },
      play: expectChips({ mode: "Full access", model: "GPT-6.2 Sol", effort: "High" }),
    },
    "codex-harness-default": {
      note: "Codex at the Harness Default level: it runs its own mode, agent, which Codex names Ask for approval; never Mode.",
      props: {
        row: codex,
        answer: { modeId: "agent", name: "Agent" },
        folder: "/Users/gallery/initial-codex-harness",
      },
      play: expectChips({ mode: "Ask for approval", effort: "High" }),
    },
    "claude-opus-medium": {
      note: "Claude Code on Opus 5.5, which acpmux starts at Medium: the model chip reads Opus 5.5 Medium from the first frame, never plain Opus 5.5.",
      props: {
        row: claude(OPUS_MEDIUM),
        answer: { modeId: "auto", name: "Auto" },
        folder: "/Users/gallery/initial-claude-opus",
      },
      play: expectChips({ mode: "Auto", model: "Opus 5.5", effort: "Medium" }),
    },
    "profile-own-model": {
      note: "A Claude Code profile that sets its own model: acpmux names no start model, only Medium, and the model chip still names a model and Medium.",
      props: {
        row: profile,
        answer: { modeId: "auto", name: "Auto" },
        folder: "/Users/gallery/initial-profile",
      },
      play: expectChips({ mode: "Auto", effort: "Medium" }),
    },
    "pi-no-modes": {
      note: "Pi has no permission modes: no Mode chip at all, not a Mode placeholder.",
      props: { row: pi, folder: "/Users/gallery/initial-pi" },
      play: expectChips({ mode: null }),
    },
  },
});
