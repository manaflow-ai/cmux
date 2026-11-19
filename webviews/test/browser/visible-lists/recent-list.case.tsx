// l10n-allow-file: test fixture paths, not shipped UI.
// The viewers' recent repositories and files (viewer-empty/EmptyState.tsx RecentList) with N items:
// two lines a row, the list 46 percent of the window tall.
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { RecentList } from "../../../src/viewer-empty/EmptyState";
import { viewerEmptyStrings } from "../../../src/viewer-empty/strings";
import "../../../src/viewer-empty/styles.css";
import type { VisibleListCase } from "./case";
import { applyCaseScale } from "./scale";

const NOW = Date.parse("2026-11-18T12:00:00Z");

const recentListCase: VisibleListCase = {
  mount(root, n) {
    (window as unknown as { __submitted: string[] }).__submitted = [];
    applyCaseScale();
    root.className = "ve-root";
    root.style.cssText = "width: 520px;";
    const items = Array.from({ length: n }, (_, index) => ({
      path: `/Users/demo/Projects/project-${index}`,
      name: `project-${index}`,
      openedAt: NOW - index * 60_000,
      branch: index % 3 === 0 ? "main" : undefined,
    }));
    flushSync(() =>
      createRoot(root).render(
        <RecentList
          items={items}
          home="/Users/demo"
          icon="repo"
          strings={viewerEmptyStrings(["en"])}
          label="Recent repositories"
          emptyText="No recent repositories"
          now={NOW}
          autoFocus={false}
          onOpen={(item) => (window as unknown as { __submitted: string[] }).__submitted.push(item.path)}
        />,
      ),
    );
    const list = () => root.querySelector<HTMLElement>("[role='listbox']")!;
    return { rowSelector: '[role="option"]', rowComponents: ["ListboxRow"], scroller: list, list };
  },
};
export default recentListCase;
