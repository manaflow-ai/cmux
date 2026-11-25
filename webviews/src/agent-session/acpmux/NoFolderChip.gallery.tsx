// l10n-allow-file: gallery fixtures (sample machines) and the rejected arms' labels, not shipped UI.
//
// The folder chip with no folder picked, on every target (Leo, 2026-11-09: "We need to be able to
// have it so, like, this no folder selected should be, like, good as well."). A chat with no folder
// starts in a folder of its own: this Mac's private agent-home folder, a Cloud machine's work
// folder, another machine's work folder. So no folder is a fine choice, not a missing field.
//
// Four arms, each on This Mac, Cloud and another machine (the real ComposerContext; the rejected
// arms only retext the chip after it draws, as the menu-grid arms in ComposerContext.gallery.tsx
// restyle it, so no presentation switch ships):
//   1. no-folder (shipped): "No folder", the folder glyph, in the same weight as a picked folder.
//   2. home: "Home" with a house glyph. Rejected: this Mac's chat never runs in ~ (AgentHome.swift
//      refuses home and above), so it would name the wrong place.
//   3. place: the folder's own name per target ("Private folder", "~/work"). Rejected: three
//      different words for one choice, and Cloud's per-chat folder is not ~/work either.
//   4. choose (the baseline): a dimmed "Choose folder" prompt, which read as a missing field.
// References (cmux-design-references): codex-mobile/live/folder-picker-menu ("Don't work in a
// project" is a row like any folder), codex-mobile/live/composer-host-and-folder,
// codex/live/composer-scope-chips-and-model-picker, and against: claude/live/composer-footer-project-
// and-model-picker ("Choose..."), claude/live/session-info-environment-and-context-panel.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ComponentProps } from "react";
import { ComposerContext } from "./ComposerContext";

type Props = ComponentProps<typeof ComposerContext>;
type Target = "mac" | "cloud" | "remote";
type Arm = "no-folder" | "home" | "place" | "choose";

const base: Props = {
  sessions: [],
  projectChoices: [
    { cwd: "/Users/you/src/atlas-web", label: "atlas-web" },
    { cwd: "/Users/you/src/cmux", label: "cmux" },
  ],
  environments: true,
  localName: "studio-mac",
  peers: ["gpu-box"],
  peerKinds: { "gpu-box": "ssh" },
  peerConnected: { "gpu-box": true },
  cloudSignedIn: true,
  stripLayout: "where-machine",
  runMode: { mode: "persistent", onMode: () => undefined },
  onProject: () => undefined,
  onBrowseProject: () => undefined,
  onNoProject: () => undefined,
  onConnect: () => undefined,
};

const TARGETS: Record<Target, { name: string; props: Props }> = {
  mac: { name: "This Mac", props: base },
  cloud: { name: "Cloud", props: { ...base, runMode: { mode: "cloud", onMode: () => undefined } } },
  remote: {
    name: "another machine (gpu-box)",
    props: { ...base, summary: { sessionId: "", harness: "claude", host: "gpu-box", peer: "gpu-box" } },
  },
};

const HOUSE =
  '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round" aria-hidden="true"><path d="M2.5 7.2 8 2.8l5.5 4.4V13a.5.5 0 0 1-.5.5H9.6V10H6.4v3.5H3a.5.5 0 0 1-.5-.5z"/></svg>';

/// A rejected arm: the drawn chip retexted (and, for Home, its glyph swapped); nothing ships.
const retext =
  (label: string, options: { glyph?: string; dim?: boolean } = {}): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-leading .acpmux-location-label"));
    const button = ctx.document.querySelector<HTMLElement>(".acpmux-location-leading .acpmux-location-button")!;
    button.querySelector(".acpmux-location-label")!.textContent = label;
    if (options.glyph) {
      const glyph = button.querySelector("svg");
      if (glyph) glyph.outerHTML = options.glyph;
    }
    if (options.dim) button.querySelector<HTMLElement>(".acpmux-location-label")!.style.color = "var(--agent-muted)";
  };

const ARMS: Record<Arm, { note: string; play?: (target: Target) => Play }> = {
  "no-folder": {
    note: 'Arm 1 of 4, shipped: "No folder" in the weight of a picked folder; the chat starts in a folder of its own there, and Add folder… stays an optional row.',
  },
  home: {
    note: 'Arm 2 of 4, rejected: "Home" with a house. This Mac\'s chat never runs in ~, so it names the wrong place.',
    play: () => retext("Home", { glyph: HOUSE }),
  },
  place: {
    note: "Arm 3 of 4, rejected: the folder's own name per target. Three words for one choice, and Cloud's per-chat folder is not ~/work.",
    play: (target) => retext(target === "mac" ? "Private folder" : "~/work"),
  },
  choose: {
    note: 'Arm 4 of 4, the baseline: a dimmed "Choose folder" prompt that read as a missing field.',
    play: () => retext("Choose folder", { dim: true }),
  },
};

const variants: Record<string, { note: string; props: Props; play?: Play }> = {};
for (const [arm, { note, play }] of Object.entries(ARMS) as [Arm, (typeof ARMS)[Arm]][])
  for (const [target, { name, props }] of Object.entries(TARGETS) as [Target, (typeof TARGETS)[Target]][])
    variants[`${arm}-${target}`] = { note: `${note} On ${name}.`, props, ...(play ? { play: play(target) } : {}) };

export default componentEntry<Props>({
  id: "agent-pane.no-folder-chip",
  title: "No folder chip",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/ComposerContext.tsx#ComposerContext"],
  styles: () => Promise.all([import("./styles.css"), import("./composerLocation.css")]),
  load: () => import("./ComposerContext").then((module) => module.ComposerContext),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 120,
  anchors: [{ selector: ".acpmux-composer-context" }],
  variants,
});
