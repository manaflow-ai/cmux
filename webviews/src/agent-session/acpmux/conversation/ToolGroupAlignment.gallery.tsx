// l10n-allow-file: gallery fixture labels and commands, not shipped copy.
// A side-by-side matrix of every collapsed tool-group shape. The real ToolGroupRow owns the
// summary, failed count, disclosure and chevron; this board makes the shared geometry easy to
// compare across short/long, failed, nested and non-command groups.
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import { useEffect } from "react";
import { TranscriptDisclosureProvider, resetTranscriptDisclosure } from "./transcriptDisclosure";
import { ToolGroupRow } from "./ToolGroupRow";
import type { ToolGroupKind } from "./toolGroups";

type Mode = "light" | "dark";
type Props = { mode: Mode };

const groups: readonly {
  id: string;
  label: string;
  kind: ToolGroupKind;
  nested?: boolean;
  items: ReturnType<typeof tool>[];
}[] = [
  {
    id: "short",
    label: "Short summary",
    kind: "commands",
    items: [tool("git status", "execute", "completed", { command: "git status" })],
  },
  {
    id: "long",
    label: "Long summary",
    kind: "commands",
    items: [
      tool("bun test webviews --filter transcript", "execute", "completed", {
        command: "bun test webviews --filter transcript",
      }),
      tool("scripts/gallery-matrix/runner.ts --entries agent-pane", "execute", "completed", {
        command: "scripts/gallery-matrix/runner.ts --entries agent-pane",
      }),
      tool("git diff --stat feat-cmux-next", "execute", "completed", { command: "git diff --stat feat-cmux-next" }),
    ],
  },
  {
    id: "failed",
    label: "Failed count",
    kind: "commands",
    items: [
      tool("bun test transcript", "execute", "completed", { command: "bun test transcript" }),
      tool("bun run lint:complexity", "execute", "failed", { command: "bun run lint:complexity", exitCode: 1 }),
    ],
  },
  {
    id: "reads",
    label: "Read group",
    kind: "reads",
    items: [tool("Read App.tsx", "read", "completed"), tool("Read conversation.css", "read", "completed")],
  },
  {
    id: "edits",
    label: "Edited file",
    kind: "edits",
    items: [tool("Edit ToolGroupRow.tsx", "edit", "completed")],
  },
  {
    id: "nested",
    label: "Nested search",
    kind: "searches",
    nested: true,
    items: [
      tool("Search for cv-tool chevrons", "search", "completed"),
      tool("Search for nested row padding", "search", "completed"),
    ],
  },
];

function ToolGroupAlignmentGallery({ mode }: Props) {
  useEffect(() => resetTranscriptDisclosure("gallery-tool-group-alignment"), []);
  return (
    <TranscriptDisclosureProvider sessionId="gallery-tool-group-alignment">
      <main className="tool-group-align-gallery" data-mode={mode} data-tool-group-alignment>
        <header className="tool-group-align-gallery__header">
          <span>Collapsed tool groups</span>
          <p>Every summary keeps one inset and pins its chevron to the trailing edge.</p>
        </header>
        <div className="tool-group-align-gallery__grid">
          {groups.map((group) => (
            <section
              key={group.id}
              className="tool-group-align-gallery__cell"
              data-group={group.id}
              data-nested={group.nested ? "true" : "false"}
            >
              <span className="tool-group-align-gallery__label">{group.label}</span>
              <div className="cv-tools">
                <ToolGroupRow kind={group.kind} items={group.items} disclosureKey={`gallery:${group.id}`} folded />
              </div>
            </section>
          ))}
        </div>
      </main>
    </TranscriptDisclosureProvider>
  );
}

const variant = (mode: Mode, note: string): ComponentVariant<Props> => ({
  note: `${note} ${mode === "dark" ? "Dark" : "Light"} theme.`,
  props: { mode },
});

export default componentEntry<Props>({
  id: "agent-pane.tool-group-alignment",
  title: "Tool-group alignment",
  area: "Agent pane",
  pane: true,
  experimental: true,
  height: 430,
  widths: { narrow: 700, normal: 980, wide: 1200 },
  anchors: [{ selector: "[data-tool-group-alignment]" }],
  covers: ["agent-session/acpmux/conversation/ToolGroupRow.tsx"],
  styles: () => import("./ToolGroupAlignment.gallery.css"),
  load: async () => ToolGroupAlignmentGallery,
  variants: {
    light: variant("light", "Six collapsed groups sit in one comparison grid."),
    dark: variant("dark", "Six collapsed groups sit in one comparison grid."),
  },
});
