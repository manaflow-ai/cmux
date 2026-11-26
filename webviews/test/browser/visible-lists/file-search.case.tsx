// acpmux/FileSearch (the "Search files" palette) answering N results, N its cap (FILE_SEARCH_LIMIT):
// the palette lists what the host answers, and the host is asked for that many.
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { FileSearch } from "../../../src/agent-session/acpmux/FileSearch";
import { caseItems, type VisibleListCase } from "./case";

function FileSearchCaseRows({ n }: { n: number }) {
  const files = caseItems(n).map((item) => `src/${item.label.replaceAll(" ", "-")}.ts`);
  return (
    <FileSearch
      search={async (query) => ({
        root: "/repo",
        results: files.filter((path) => path.includes(query.replaceAll(" ", "-"))).map((path) => ({ path })),
      })}
      onPick={(path) => (window as unknown as { __submitted: string[] }).__submitted.push(path)}
      onClose={() => {}}
      debounceMs={0}
    />
  );
}

const fileSearchCase: VisibleListCase = {
  async mount(root, n) {
    (window as unknown as { __submitted: string[] }).__submitted = [];
    const style = document.createElement("style");
    style.textContent =
      ".acpmux-file-search [role='listbox'] { height: 320px; overflow: auto; } .acpmux-file-result { height: 28px; box-sizing: border-box; }";
    document.head.append(style);
    flushSync(() => createRoot(root).render(<FileSearchCaseRows n={n} />));
    // A query every row matches, so the palette lists all N.
    const input = root.querySelector<HTMLInputElement>("input")!;
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, "src");
    input.dispatchEvent(new Event("input", { bubbles: true }));
    const list = () => root.querySelector<HTMLElement>("[role='listbox']")!;
    while (list().querySelectorAll("[role='option']").length < Math.min(n, 1))
      await new Promise((done) => requestAnimationFrame(done));
    return {
      rowSelector: '[role="option"]',
      rowComponents: ["FileResultRow"],
      scroller: list,
      list,
      filter: () => input,
    };
  },
};
export default fileSearchCase;
