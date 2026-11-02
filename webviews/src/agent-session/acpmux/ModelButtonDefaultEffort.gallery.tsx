// l10n-allow-file: gallery fixtures exercise picker states and labels, not shipped copy.
import { useMemo, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { ComposerPickers } from "./ComposerPickers";
import { UpdateOfferContext, type UpdateOffer } from "./HarnessHealthNotice";
import type { AcpmuxSnapshot } from "./model";
import { BUNDLED_MODEL_CATALOG, buildPickerCatalog } from "./modelCatalogData";

// Leo 2026-10-22 on a claude-sr2 chat: "this should just show the effort too right? and then the
// effort tells you what you're already currrently on?" The chat ran the agent's default effort on
// a Claude Code profile the model catalog does not map; its model button names the model's own
// level (Medium) and the inline effort control checks it.

type Props = { effort: string; update?: boolean };

// An agent CLI update on offer: the button once drew a dot between the model and its effort
// ("Opus 5.5 • Medium"; Leo 2026-10-22: "BRO WTF NO WE FUCKING HATE THE DOT").
const UPDATE: UpdateOffer = {
  harness: "claude-sr2",
  agent: "Claude Code",
  version: "2.1.300",
  latest: "2.1.301",
  update: () => undefined,
  skip: () => undefined,
};

const PROFILE_MODELS = [
  { id: "default", name: "Default (Claude Code's choice)" },
  { id: "opus", name: "Opus" },
  { id: "claude-opus-5-5", name: "Opus 5.5" },
  { id: "claude-fable-5-1", name: "Fable 5.1" },
  { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
];

const catalog = [
  ...BUNDLED_MODEL_CATALOG.harnesses.map((harness) => ({
    id: harness.id,
    name: harness.name,
    family: harness.families[0],
    models: harness.models.map((model) => ({ id: model.id, name: model.name })),
  })),
  { id: "claude-sr2", name: "claude-sr2", family: "claude-sr2", models: PROFILE_MODELS },
] as AcpmuxSnapshot["catalog"];

function snapshotFor(effort: string): AcpmuxSnapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "gallery",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog,
    summary: {
      sessionId: "gallery-default-effort",
      harness: "claude-sr2",
      family: "claude-sr2",
      model: "claude-opus-5-5",
      turnCount: 1,
      configOptions: [
        {
          id: "model",
          name: "Model",
          category: "model",
          currentValue: "claude-opus-5-5",
          options: PROFILE_MODELS.map((model) => ({ value: model.id, name: model.name })),
        },
        {
          id: "effort",
          name: "Reasoning",
          category: "thought_level",
          currentValue: effort,
          options: [
            { value: "default", name: "Default" },
            { value: "low", name: "Low" },
            { value: "medium", name: "Medium" },
            { value: "high", name: "High" },
            { value: "xhigh", name: "Extra High" },
            { value: "max", name: "Max" },
          ],
        },
      ],
    },
  } as AcpmuxSnapshot;
}

function GalleryDefaultEffort({ effort: initialEffort, update }: Props) {
  const [effort, setEffort] = useState(initialEffort);
  const snapshot = useMemo(() => snapshotFor(effort), [effort]);
  const pickerCatalog = useMemo(
    () =>
      buildPickerCatalog({
        catalog: BUNDLED_MODEL_CATALOG,
        user: undefined,
        acpmux: snapshot.catalog,
        session: { harness: snapshot.summary!.harness, configOptions: snapshot.summary!.configOptions },
      }),
    [snapshot],
  );
  return (
    <UpdateOfferContext.Provider value={update ? UPDATE : undefined}>
      <div className="acpmux-composer-gallery-shell">
        <ComposerPickers
          snapshot={snapshot}
          pickerCatalog={pickerCatalog}
          onModel={() => undefined}
          onMode={() => undefined}
          onEffort={(_id, value) => setEffort(value)}
          showPlan={false}
        />
      </div>
    </UpdateOfferContext.Provider>
  );
}

const MODEL = { role: "button", name: "Model" } as const;

/// The running model's effort is a side dropdown beside its row (#27948): open it, then wait for its
/// checked level. A menu without one keeps its levels in the menu itself.
const RUNNING_EFFORT = ".acpmux-quick-model-effort[data-running] .acpmux-quick-effort-trigger";
const openEffort: Play = async (ctx) => {
  await ctx.click(MODEL);
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(RUNNING_EFFORT) !== null ||
      ctx.document.querySelector('.acpmux-quick-menu .acpmux-quick-effort-segment[aria-checked="true"]') !== null,
  );
  if (ctx.document.querySelector(RUNNING_EFFORT)) {
    // A submenu trigger opens on hover or from the keyboard: focus it and press ArrowRight.
    await ctx.focus({ selector: RUNNING_EFFORT });
    await ctx.press("ArrowRight");
  }
  await ctx.waitFor(
    () => ctx.document.querySelector('.acpmux-quick-menu .acpmux-quick-effort-segment[aria-checked="true"]') !== null,
  );
};

export default componentEntry<Props>({
  id: "agent-pane.model-button-default-effort",
  title: "Model button on the agent's default effort",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 400, normal: 640, wide: 860 },
  anchors: [{ selector: ".acpmux-chips" }],
  covers: ["agent-session/acpmux/ComposerPickers.tsx#ComposerPickers"],
  load: async () => GalleryDefaultEffort,
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./composerControls.css"),
      import("./modelPicker.css"),
      import("./ComposerPickers.gallery.css"),
    ]),
  variants: {
    "profile-default": {
      note: "A claude-sr2 chat on the agent's default effort: the button reads Opus 5.5 and the model's own level, Medium.",
      props: { effort: "default" },
    },
    "profile-default-effort-menu": {
      note: "Its effort dropdown checks Medium with the menus' own check.",
      props: { effort: "default" },
      play: openEffort,
    },
    "profile-update-pending": {
      note: "With a Claude Code update on offer the button still reads Opus 5.5 Medium: no dot, bullet or middot between them.",
      props: { effort: "default", update: true },
    },
    "profile-picked-high": {
      note: "A level the chat picked wins: the button reads High and the effort dropdown checks High.",
      props: { effort: "high" },
      play: openEffort,
    },
  },
});
