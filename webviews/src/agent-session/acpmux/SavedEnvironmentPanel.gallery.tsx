// l10n-allow-file: gallery fixtures (sample folders, machines and names), not shipped UI.
//
// Create environment and Edit environment on the New Tab page (preview): the inline panel under
// the composer, for a folder on this computer in a worktree and for a folder on an SSH machine.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ComponentProps } from "react";
import { SavedEnvironmentPanel } from "./SavedEnvironmentPanel";

const folders = [
  { id: "/Users/you/src/atlas-web", label: "atlas-web" },
  { id: "/Users/you/src/cmux", label: "cmux" },
];

const browseError: ComponentProps<typeof SavedEnvironmentPanel> = {
  initial: { kind: "local", folder: folders[0]!.id },
  folders,
  onBrowse: async () => {
    throw new Error("The folder chooser is unavailable.");
  },
  machines: [],
  machineFolders: () => [],
  onSave: async () => undefined,
  onRemove: () => undefined,
  onClose: () => undefined,
};

const baseProps: ComponentProps<typeof SavedEnvironmentPanel> = {
  initial: { kind: "local", folder: folders[0]!.id },
  folders,
  onBrowse: async () => undefined,
  machines: ["gpu-box", "build-server"],
  machineFolders: (machine) =>
    machine === "gpu-box" ? [{ id: "/home/dev/model", label: "model" }] : [{ id: "/srv/ci", label: "ci" }],
  onConnectSSH: () => undefined,
  onSave: async () => undefined,
  onRemove: () => undefined,
  onClose: () => undefined,
};

/** The Host select open: its menu starts at the field's leading edge and is at least as wide. */
const openHost: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-env-select"));
  await ctx.click({ selector: ".acpmux-env-select" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] [role="menuitemradio"]'));
};

const sshEnvironment = {
  id: "s1",
  name: "GPU box training",
  kind: "ssh",
  host: "gpu-box",
  folder: "/home/dev/model",
  updatedAt: 3,
} as const;

export default componentEntry<ComponentProps<typeof SavedEnvironmentPanel>>({
  id: "agent-pane.saved-environment-panel",
  title: "Saved environment panel",
  area: "Agent pane",
  covers: ["agent-session/acpmux/SavedEnvironmentPanel.tsx#SavedEnvironmentPanel"],
  styles: () => Promise.all([import("./styles.css"), import("./savedEnvironments.css")]),
  load: () => import("./SavedEnvironmentPanel").then((module) => module.SavedEnvironmentPanel),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 320,
  anchors: [{ selector: ".acpmux-env-panel" }],
  variants: {
    "create-local": {
      note: "Create environment starts where the page would start: this computer and its folder.",
      props: baseProps,
    },
    "edit-local-worktree": {
      note: "Edit environment of a folder on this computer that starts each chat in a new worktree, with Remove.",
      props: {
        ...baseProps,
        environment: {
          id: "l1",
          name: "Atlas in a worktree",
          kind: "local",
          folder: folders[0]!.id,
          worktree: true,
          updatedAt: 2,
        },
      },
    },
    "edit-ssh": {
      note: "An SSH environment: its machine and a folder there; no worktree.",
      props: { ...baseProps, environment: sshEnvironment },
    },
    "ssh-host-open": {
      note: "The Host select open: the menu starts at the field's leading edge and is at least as wide.",
      props: { ...baseProps, environment: sshEnvironment },
      play: openHost,
    },
    "browse-error": {
      note: "A rejected native folder chooser stays in the environment panel with its reason and a Retry action.",
      props: browseError,
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-location-button" });
        await ctx.waitFor(() => ctx.document.querySelector("[data-choose]"));
        await ctx.click({ selector: "[data-choose]" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-env-error"));
      },
    },
  },
});
