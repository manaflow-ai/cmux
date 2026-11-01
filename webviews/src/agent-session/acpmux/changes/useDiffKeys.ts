// The changes view's own keys: j and k move between files, n and p between changes, v marks the
// picked file viewed (or not), and s (in Unstaged) or u (in Staged) stages or unstages the hunk
// n/p stopped at. They are
// the view's reading keys, like a list's arrows, so they are drawn as they are (DiffKeyHints)
// rather than bound in Settings, and work only while focus is in the view and not in a field.
import { useEffect, type RefObject } from "react";
import { changeStarts, fileSections, READING_LINE, stepTarget } from "./diffNavigation";

/// The row a change step landed on, marked in its diff so the reader sees where n/p stopped.
export const CURRENT_CHANGE = "data-acpmux-current";

const typing = (target: EventTarget | null) =>
  target instanceof Element &&
  (target.closest("input, textarea, select, [contenteditable]:not([contenteditable='false'])") !== null ||
    target.getAttribute("role") === "textbox");

export function useDiffKeys(
  panel: RefObject<HTMLElement | null>,
  body: RefObject<HTMLElement | null>,
  /// Shows a file, as picking it in the tree does: selects it and scrolls its header to the top.
  revealFile: (path: string) => void,
  /// The file last picked, in the tree or with j/k.
  selectedFile: () => string | undefined,
  /// The key that presses the current hunk's Stage hunk (`s`) or Unstage hunk (`u`), if any.
  hunkKey?: "s" | "u",
) {
  useEffect(() => {
    const node = panel.current;
    if (!node) return;
    let current: HTMLElement | undefined;
    const onKey = (event: KeyboardEvent) => {
      const scroller = body.current;
      if (!scroller || event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
      // A field in a shadow root (Pierre's) targets its host here; the composed path has the field.
      if (event.isComposing || typing(event.composedPath()[0] ?? event.target)) return;
      if (event.key === hunkKey) {
        // The change n/p marked while it shows, else the first change in view: its hunk's button
        // is the first one below the change's first row in the same file (HunkStage sits under
        // the hunk's last row). A file without them (new, deleted) stages nothing.
        const box = scroller.getBoundingClientRect();
        const shows = (row: HTMLElement) => {
          const top = row.getBoundingClientRect().top;
          return top >= box.top - 1 && top <= box.top + scroller.clientHeight;
        };
        const row = current?.isConnected && shows(current) ? current : changeStarts(scroller).find(shows);
        event.preventDefault();
        const root = row?.getRootNode();
        const file =
          root instanceof ShadowRoot ? root.host.closest(".acpmux-diff-file") : row?.closest(".acpmux-diff-file");
        if (!row || !file) return;
        const from = row.getBoundingClientRect().top;
        [...file.querySelectorAll<HTMLButtonElement>(".acpmux-hunk-stage")]
          .find((button) => button.getBoundingClientRect().top > from)
          ?.click();
        return;
      }
      if (event.key === "v" && !event.shiftKey) {
        // The picked file while any of its edit sections shows, else the first section in view: a
        // file edited more than once has a section (and header) per edit, and `fileSections` keeps
        // only the first of them. The toggle is keyed by path, so any shown section's button does.
        const sections = [...scroller.querySelectorAll<HTMLElement>(".acpmux-diff-file")];
        const box = scroller.getBoundingClientRect();
        const shows = (section: HTMLElement) => {
          const { top, bottom } = section.getBoundingClientRect();
          return bottom > box.top && top < box.top + scroller.clientHeight;
        };
        const pickedPath = selectedFile();
        const section =
          sections.find((candidate) => candidate.dataset.path === pickedPath && shows(candidate)) ??
          sections.find(shows);
        event.preventDefault();
        section?.querySelector<HTMLButtonElement>("[data-viewed-toggle]")?.click();
        return;
      }
      if (!["j", "k", "n", "p"].includes(event.key)) return;
      const step = event.key === "j" || event.key === "n" ? 1 : -1;
      const box = scroller.getBoundingClientRect();
      if (event.key === "j" || event.key === "k") {
        const sections = fileSections(scroller);
        const tops = sections.map((section) => section.getBoundingClientRect().top);
        // Steps go from the picked file while it shows: a file near the end can't scroll to the
        // top, so measuring from the top would pick it again. Otherwise from the top of the view.
        const picked = sections.findIndex((section) => section.dataset.path === selectedFile());
        const shows =
          picked !== -1 && tops[picked]! < box.top + scroller.clientHeight && (tops[picked + 1] ?? Infinity) > box.top;
        const index = shows ? sections[picked + step] && picked + step : stepTarget(tops, box.top, step);
        event.preventDefault();
        if (index !== undefined) revealFile(sections[index]!.dataset.path ?? "");
        return;
      }
      const starts = changeStarts(scroller);
      const line = box.top + scroller.clientHeight * READING_LINE;
      // Steps go from the change the last step marked while it is in view; otherwise (none yet,
      // or the reader scrolled away) the first change in view is the first stop.
      const marked = current?.isConnected ? current.getBoundingClientRect().top : undefined;
      const from =
        marked !== undefined && marked >= box.top && marked <= box.top + scroller.clientHeight
          ? marked
          : step === 1
            ? box.top - 2
            : line;
      const index = stepTarget(
        starts.map((row) => row.getBoundingClientRect().top),
        from,
        step,
      );
      event.preventDefault();
      if (index === undefined) return;
      const target = starts[index]!;
      current?.removeAttribute(CURRENT_CHANGE);
      target.setAttribute(CURRENT_CHANGE, "");
      current = target;
      scroller.scrollTop += target.getBoundingClientRect().top - line;
    };
    node.addEventListener("keydown", onKey);
    return () => {
      node.removeEventListener("keydown", onKey);
      current?.removeAttribute(CURRENT_CHANGE);
    };
  }, [panel, body, revealFile, selectedFile, hunkKey]);
}
