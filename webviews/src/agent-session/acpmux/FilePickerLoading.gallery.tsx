// Made-up files and unresolved requests keep the initial loading state reproducible.
import { useEffect, useRef } from "react";
import { componentEntry } from "../../gallery/format";
import { FileSearch } from "./FileSearch";
import type { FileSearchSource } from "./fileSearchModel";
import { MentionMenu, type MentionState } from "./MentionMenu";
import { mentionItems } from "./mentionItems";

type Props = { surface: "files" | "mentions"; state: "pending" | "loaded" | "empty" | "failed" };
const results = [
  { path: "src/example.ts", matches: [] },
  { path: "src/components/example-card.tsx", matches: [] },
  { path: "test/example.test.ts", matches: [] },
];
const searches: Record<Props["state"], FileSearchSource> = {
  pending: () => new Promise(() => {}),
  loaded: async () => ({ root: "/project", results }),
  empty: async () => ({ root: "/project", results: [] }),
  failed: async () => {
    throw new Error("unavailable");
  },
};
function FilePickerLoadingFixture({ surface, state }: Props) {
  const host = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (surface !== "files") return;
    const input = host.current?.querySelector("input");
    if (!input) return;
    // Use the real field's change boundary; do not expose fixture state in product props.
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, "example");
    input.dispatchEvent(new Event("input", { bubbles: true }));
  }, [surface, state]);
  const files = state === "loaded" ? results : [];
  const mentionState: MentionState =
    state === "pending"
      ? { kind: "searching", results: [] }
      : state === "failed"
        ? { kind: "failed" }
        : { kind: "done", results: files };
  return (
    <section className="acpmux-shell">
      <div ref={host} style={{ position: "relative", width: "100%", height: "100%" }}>
        {surface === "files" ? (
          <FileSearch key={state} search={searches[state]} debounceMs={0} onPick={() => {}} onClose={() => {}} />
        ) : (
          <div style={{ position: "absolute", insetInline: "var(--ds-space-4)", top: "70%" }}>
            <MentionMenu
              state={mentionState}
              items={mentionItems({ query: "example", files, sessions: [] })}
              active={state === "loaded" ? 0 : -1}
              onHover={() => {}}
              onPick={() => {}}
            />
          </div>
        )}
      </div>
    </section>
  );
}
export default componentEntry<Props>({
  id: "agent-pane.file-picker-loading",
  title: "File picker loading",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/FileSearch.tsx#FileSearch", "agent-session/acpmux/MentionMenu.tsx#MentionMenu"],
  load: async () => FilePickerLoadingFixture,
  styles: () => import("./styles.css"),
  widths: { narrow: 320, normal: 520 },
  height: 320,
  variants: {
    "files-pending": { props: { surface: "files", state: "pending" } },
    "files-loaded": { props: { surface: "files", state: "loaded" } },
    "files-empty": { props: { surface: "files", state: "empty" } },
    "files-failed": { props: { surface: "files", state: "failed" } },
    "mentions-pending": { props: { surface: "mentions", state: "pending" } },
    "mentions-loaded": { props: { surface: "mentions", state: "loaded" } },
    "mentions-empty": { props: { surface: "mentions", state: "empty" } },
    "mentions-failed": { props: { surface: "mentions", state: "failed" } },
  },
});
