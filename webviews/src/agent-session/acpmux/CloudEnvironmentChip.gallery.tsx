// l10n-allow-file: gallery fixtures (sample folders and environment names), not shipped UI.
//
// The Cloud Environment chip (CloudEnvironmentChip.tsx, behind CLOUD_ENVIRONMENTS_ENABLED). Leo,
// 2026-11-07: "you pick the cloud thing, and then you have another thing, drop down, or, you know,
// drop up, that is, because you don't want to hide the composer. So the drop up, it goes, like,
// it's auto by default, but then you can also say create environment." The stage is a new chat's
// composer at the bottom of the pane (a chat) or at the top (the New Tab page): the drop-up opens
// above the chip in both, and never over the box under it.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { ComposerContext } from "./ComposerContext";
import type { CloudEnvironmentDropUp } from "./CloudEnvironmentChip";
import { AUTO_ENVIRONMENT, type CloudEnvironmentControl } from "./cloudEnvironmentChoice";

type StageProps = {
  /// Where the composer sits: the chat's bottom, or the New Tab page's top half.
  place: "bottom" | "top";
  /// Where the chat runs when the stage opens.
  where: "local" | "cloud";
  dropUp: CloudEnvironmentDropUp;
  /// The pick: Auto or one of the recent environments.
  current?: string;
  recent?: number;
  /// The project's default from the service (an id, or AUTO_ENVIRONMENT for none set); absent: a
  /// service without per-project defaults, so the local recents stand in.
  projectDefault?: string;
  /// A started chat on this Mac: the chip sits beside the picker for Move to Cloud.
  move?: boolean;
  /// An iPhone-wide composer (375 px), whatever the stage's width.
  phone?: boolean;
};

const environments = [
  { id: "env_web", name: "atlas-web" },
  { id: "env_gpu", name: "GPU training" },
  { id: "env_docs", name: "docs preview" },
];

function Stage({
  place,
  where,
  dropUp,
  current = AUTO_ENVIRONMENT,
  recent = 2,
  projectDefault,
  move,
  phone,
}: StageProps) {
  const [mode, setMode] = useState<"persistent" | "cloud">(where === "cloud" ? "cloud" : "persistent");
  const [pick, setPick] = useState(current);
  const [projectPick, setProjectPick] = useState(projectDefault);
  const control: CloudEnvironmentControl = {
    ...(projectPick !== undefined
      ? { projectDefault: projectPick, onMakeDefault: (id?: string) => setProjectPick(id ?? AUTO_ENVIRONMENT) }
      : {}),
    recent: environments.slice(0, recent),
    current: pick,
    auto: { id: "env_default", name: "Default" },
    onPick: setPick,
    onNew: () => undefined,
    onEdit: () => undefined,
    onNewMachine: () => undefined,
  };
  const composer = (
    <form className="acpmux-composer" onSubmit={(event) => event.preventDefault()}>
      <ComposerContext
        environments
        stripLayout="where-machine"
        {...(move ? { started: true, offloads: ["move"] as const, onOffload: () => undefined } : {})}
        summary={{ sessionId: move ? "chat-1" : "", harness: "claude", host: "This Mac", hostKind: "local" } as never}
        localName="studio-mac"
        projectChoices={[{ cwd: "/Users/you/src/atlas-web", label: "atlas-web" }]}
        onProject={() => undefined}
        onConnect={() => undefined}
        cloudSignedIn
        runMode={{ mode, onMode: (next) => setMode(next === "cloud" ? "cloud" : "persistent") }}
        cloudEnvironment={control}
        cloudEnvironmentDropUp={dropUp}
      />
      <div className="acpmux-composer-box" data-gallery-box="">
        <textarea aria-label="Prompt" placeholder="Ask anything" rows={3} />
      </div>
    </form>
  );
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        justifyContent: place === "bottom" ? "flex-end" : "flex-start",
        height: "100%",
        boxSizing: "border-box",
        ...(phone ? { maxWidth: 375 } : {}),
        padding: place === "bottom" ? "0 12px 12px" : "0 12px",
      }}
    >
      {/* The New Tab page's hero above its composer: about a third of the window. */}
      {place === "top" && <div style={{ flex: "0 0 35%" }} />}
      {composer}
    </div>
  );
}

/// Opens the chip's drop-up, then checks the one rule it must keep: it is above the chip and never
/// over the composer's box.
const openDropUp: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-cloud-env-slot[data-shown="true"] button'));
  await ctx.click({ selector: '.acpmux-cloud-env-slot[data-shown="true"] button' });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cloud-env-menu [role='menuitemradio']"));
  const menu = ctx.document.querySelector(".acpmux-cloud-env-menu")!.getBoundingClientRect();
  const box = ctx.document.querySelector("[data-gallery-box]")!.getBoundingClientRect();
  const chip = ctx.document.querySelector(".acpmux-cloud-env")!.getBoundingClientRect();
  if (menu.bottom > box.top + 0.5) throw new Error(`drop-up covers the composer: ${menu.bottom} > ${box.top}`);
  if (menu.bottom > chip.top + 0.5) throw new Error(`drop-up is not above its chip: ${menu.bottom} > ${chip.top}`);
};

/// Picks Cloud in the Where chip: the Environment chip opens beside it.
const pickCloud: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('[data-rows="where"] button'));
  await ctx.click({ selector: '[data-rows="where"] button' });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-row[data-mode="cloud"]'));
  await ctx.click({ selector: '.acpmux-env-row[data-mode="cloud"]' });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-cloud-env-slot[data-shown="true"]'));
};

/// A started chat's Move to Cloud: the chip beside the picker opens the same drop-up.
const openMoveDropUp: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-cloud-env-slot[data-for="move"] button'));
  await ctx.click({ selector: '.acpmux-cloud-env-slot[data-for="move"] button' });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cloud-env-menu [role='menuitemradio']"));
};

const base = { place: "bottom", where: "cloud", dropUp: "list" } as const;

export default componentEntry<StageProps>({
  id: "agent-pane.cloud-environment-chip",
  title: "Cloud environment chip",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/CloudEnvironmentChip.tsx#CloudEnvironmentChip"],
  styles: () =>
    Promise.all([import("./styles.css"), import("./composerLocation.css"), import("./cloudEnvironmentChip.css")]),
  load: async () => Stage,
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 420,
  anchors: [{ selector: ".acpmux-composer-context" }],
  variants: {
    "this-mac": {
      note: "This Mac picked: no Environment chip (its slot is closed and inert).",
      props: { ...base, where: "local" },
    },
    "cloud-auto": {
      note: "Cloud picked: Environment: Auto beside the Where chip. Auto makes an environment from the chat's folder or repository on its first Cloud chat, with no questions.",
      props: base,
    },
    "pick-cloud": {
      note: "This Mac, then Cloud picked: the chip's column opens from nothing as it fades in; Project and Where do not move.",
      props: { ...base, where: "local" },
      play: pickCloud,
    },
    "drop-up-list": {
      note: "Shipped. The drop-up opens up, never over the composer: Auto, the project's recent environments, New environment…, Edit Default…, then New Cloud machine… after a hairline. One line each, no headers.",
      props: base,
      play: openDropUp,
    },
    "drop-up-gear": {
      note: "Variant: each recent environment carries its own edit gear (shown on hover), beside the same Edit row for the current one.",
      props: { ...base, dropUp: "gear" },
      play: openDropUp,
    },
    "drop-up-sections": {
      note: "Variant: Environment and Machine headers over the same rows.",
      props: { ...base, dropUp: "sections" },
      play: openDropUp,
    },
    "drop-up-picked": {
      note: "An environment picked: the chip names it, its row is checked, and Edit names it.",
      props: { ...base, current: "env_gpu" },
      play: openDropUp,
    },
    "drop-up-new-tab": {
      note: "The New Tab page's composer, in the window's top half: the drop-up still opens up, away from the box.",
      props: { ...base, place: "top" },
      play: openDropUp,
    },
    "project-default": {
      note: "The project has a default on the service: the chat starts on it, its row comes first and is marked Default; the local recents are not read.",
      props: { ...base, current: "env_gpu", projectDefault: "env_gpu" },
      play: openDropUp,
    },
    "make-default": {
      note: "Another environment picked: Make default for this project, after Edit, moves the Default mark to it.",
      props: { ...base, current: "env_web", projectDefault: "env_gpu" },
      play: openDropUp,
    },
    "no-project-default": {
      note: "The service keeps per-project defaults but this project has none: Make default for this project is offered on any pick but Auto.",
      props: { ...base, current: "env_docs", recent: 3, projectDefault: AUTO_ENVIRONMENT },
      play: openDropUp,
    },
    "move-to-cloud": {
      note: "A started chat on this Mac: the Environment chip beside the picker names the environment Move to Cloud's new machine boots in.",
      props: { ...base, where: "local", move: true, projectDefault: "env_web", current: "env_web" },
      play: openMoveDropUp,
    },
    "phone-project-default": {
      note: "iPhone width: the drop-up with the Default mark and Make default; rows keep one line, the mark stays at the end.",
      props: { ...base, current: "env_web", projectDefault: "env_gpu", phone: true },
      play: openDropUp,
    },
    "phone-move-to-cloud": {
      note: "iPhone width: Move to Cloud's chip beside a started chat's picker drops its prefix and keeps the value.",
      props: { ...base, where: "local", move: true, projectDefault: "env_web", current: "env_web", phone: true },
      play: openMoveDropUp,
    },
    "first-chat": {
      note: "A first Cloud chat with no environments yet: Auto, New environment…, Edit Default…, New Cloud machine….",
      props: { ...base, recent: 0 },
      play: openDropUp,
    },
  },
});
