// l10n-allow-file: gallery fixture (an entry title and sample file rows), not shipped UI.
// Made-up listings of a chat's own machine, as its daemon's `agent-session-list-dir` answers them.
import { componentEntry } from "../../gallery/format";
import { MachineFiles } from "./MachineFiles";
import type { MachineFilesList } from "./machineFilesModel";

type Props = { state: "project" | "loading" | "empty" | "denied" | "truncated" };
const project = {
  path: "/home/me/work/shop",
  parent: "/home/me/work",
  entries: [
    { name: "src", path: "/home/me/work/shop/src", kind: "dir" },
    { name: "web", path: "/home/me/work/shop/web", kind: "dir", repo: true },
    { name: "package.json", path: "/home/me/work/shop/package.json", kind: "file" },
    { name: "README.md", path: "/home/me/work/shop/README.md", kind: "file" },
    { name: "vite.config.ts", path: "/home/me/work/shop/vite.config.ts", kind: "file" },
  ],
};
const lists: Record<Props["state"], MachineFilesList> = {
  project: async () => project,
  loading: () => new Promise(() => {}),
  empty: async () => ({ path: "/home/me/work/new", parent: "/home/me/work", entries: [] }),
  denied: async () => ({
    error: { code: "list_dir.denied", message: "This machine does not let cmux read that folder" },
  }),
  truncated: async () => ({
    path: "/home/me/work/logs",
    parent: "/home/me/work",
    entries: Array.from({ length: 40 }, (_, index) => ({
      name: `run-${index}.log`,
      path: `/home/me/work/logs/run-${index}.log`,
      kind: "file",
    })),
    truncated: true,
  }),
};

function MachineFilesFixture({ state }: Props) {
  return (
    <section className="acpmux-shell">
      <div style={{ position: "relative", width: "100%", height: "100%" }}>
        <MachineFiles key={state} list={lists[state]} onOpenFile={() => {}} onClose={() => {}} />
      </div>
    </section>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.machine-files",
  title: "Browse files on this machine",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/MachineFiles.tsx#MachineFiles"],
  load: async () => MachineFilesFixture,
  styles: () => import("./styles.css"),
  widths: { narrow: 320, normal: 520 },
  height: 360,
  variants: {
    project: { note: "A chat's folder on another machine: folders first, then files.", props: { state: "project" } },
    loading: { props: { state: "loading" } },
    empty: { props: { state: "empty" } },
    denied: { note: "The machine's own sentence, with Try again.", props: { state: "denied" } },
    truncated: {
      note: "More items than the machine lists: the first ones, and a line saying so.",
      props: { state: "truncated" },
    },
  },
});
