// l10n-allow-file: gallery fixtures (sample folders and machines), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { CloudFolderlessDesignsProps } from "./CloudFolderlessDesigns";

const cloud = { mode: "cloud" as const, onMode: () => undefined };
const base = {
  sessions: [],
  peers: ["gpu-box"],
  peerKinds: { "gpu-box": "ssh" as const },
  projectChoices: [
    { cwd: "/Users/you/src/atlas-web", label: "atlas-web" },
    { cwd: "/Users/you/src/cmux", label: "cmux" },
  ],
  localName: "This Mac",
  environments: true,
  stripLayout: "where-machine" as const,
  cloudSignedIn: true,
  runMode: cloud,
  summary: { sessionId: "", harness: "claude", host: "This Mac", hostKind: "local" as const },
  onProject: () => undefined,
  onBrowseProject: () => undefined,
  onNoProject: () => undefined,
  onConnect: () => undefined,
} satisfies Omit<CloudFolderlessDesignsProps, "design">;

const openFolderMenu: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Folder/ });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-folder-popover .acpmux-location-note"));
};

/// Another design's words on the shipped chip (CloudFolderlessDesigns.tsx): `dim` as the old empty pick.
const relabel =
  (words: string, dim = false): Play =>
  async (ctx) => {
    const find = () =>
      ctx.document.querySelector<HTMLElement>('.acpmux-location-label[data-folder-state="cloudFresh"]');
    await ctx.waitFor(find);
    const label = find();
    if (!label) return;
    label.textContent = words;
    if (dim) label.setAttribute("data-dim", "");
  };

export default componentEntry<CloudFolderlessDesignsProps>({
  id: "agent-pane.cloud-folderless",
  title: "Cloud with no folder: the folder chip (designs)",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/CloudFolderlessDesigns.tsx#CloudFolderlessDesigns",
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
  ],
  styles: () => Promise.all([import("./styles.css"), import("./composerLocation.css")]),
  load: () => import("./CloudFolderlessDesigns").then((module) => module.CloudFolderlessDesigns),
  widths: { narrow: 400, normal: 620 },
  height: 420,
  variants: {
    "menu-note": {
      note: "Picked, and the one that ships: the chip reads No folder (not dimmed); where the chat starts is one line in the folder menu and the chip's description, never narration in the strip.",
      props: { ...base, design: "menu-note" },
    },
    "menu-note-open": {
      note: "The same, folder menu open: No folder is checked, Add folder… and the projects still pick a folder, and the quiet line says the chat starts in a fresh home on the machine.",
      props: { ...base, design: "menu-note" },
      play: openFolderMenu,
    },
    "inline-detail": {
      note: "The detail after the label in the strip: clearer at a glance, but it narrates a routine state (design/composer.md rule 2) and crowds the narrow strip.",
      props: { ...base, design: "inline-detail" },
    },
    "fresh-home": {
      note: "The chip names the place, Fresh home, instead of the absence: reads as a choice, but hides that a folder can still be picked.",
      props: { ...base, design: "fresh-home" },
      play: relabel("Fresh home"),
    },
    before: {
      note: "Before: the empty, dimmed Choose folder Leo saw beside Cloud (the half state this replaces).",
      props: { ...base, design: "before" },
      play: relabel("Choose folder", true),
    },
    "folder-picked": {
      note: "Cloud with a folder picked: the folder's name, as before (it is copied to the machine).",
      props: {
        ...base,
        design: "menu-note",
        summary: { ...base.summary, cwd: "/Users/you/src/cmux" },
      },
    },
    "started-fresh-folder": {
      note: "A started folderless Cloud chat in the fresh folder its machine made (~/chats/<chat>): the chip names that folder as the machine has it, never No folder; /cd or cmux chat cd moves it to a repository.",
      props: {
        ...base,
        design: "menu-note",
        started: true,
        onNewChat: () => undefined,
        peers: ["zesty-indigo-lemur"],
        peerKinds: { "zesty-indigo-lemur": "cloud" as const },
        summary: {
          sessionId: "s-1",
          harness: "claude",
          host: "zesty-indigo-lemur",
          hostKind: "cloud" as const,
          peer: "zesty-indigo-lemur",
          cwd: "/home/cmux/chats/peer-4242",
        },
      },
    },
  },
});
