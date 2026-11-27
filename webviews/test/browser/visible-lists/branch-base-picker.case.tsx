// The diff viewer's Base picker (BranchBasePicker.tsx), open, over N refs spread across the five
// groups the sidecar sends. Every ref's label starts with the harness's typed query ("item 0123"),
// so each key of a typing step matches all N refs: the filtered list is as long as it can be.
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { BranchBasePicker, type BranchPickerPayload } from "../../../src/BranchBasePicker";
import type { BranchPickerGroup } from "../../../src/diff/generated/protocol";
import type { VisibleListCase } from "./case";

const GROUPS = ["suggested", "worktrees", "branches", "remotes", "recent"];

function refGroups(n: number): BranchPickerGroup[] {
  const groups: BranchPickerGroup[] = GROUPS.map((id) => ({ id, label: id, rows: [] }));
  for (let index = 0; index < n; index++) {
    const ref = `item 0123 ${String(index).padStart(5, "0")}`;
    groups[index % groups.length]!.rows.push({ ref, label: ref, ...(index === 0 ? { current: true } : {}) });
  }
  return groups;
}

const label = (key: string) => key;
const onNavigate = () => {};
/** The ref a selection chose, for a behaviour check. */
const onSelectBranchBase = (ref: string) => {
  (window as unknown as { __picked?: string }).__picked = ref;
};

const picker: BranchPickerPayload = {
  repoRoot: "/repo",
  capabilityToken: "token",
  headRef: "HEAD",
  currentRef: "item 0123 00000",
  currentReason: "",
  confidence: "high",
  aheadBehind: null,
  refsURL: "",
  regenerateURLTemplate: "",
};

const branchBasePickerCase: VisibleListCase = {
  async mount(root, n) {
    const groups = refGroups(n);
    const transport = { request: async () => ({ type: "branches", value: { groups } }) };
    flushSync(() =>
      createRoot(root).render(
        <BranchBasePicker
          label={label as never}
          onNavigate={onNavigate}
          onSelectBranchBase={onSelectBranchBase}
          picker={picker}
          transport={transport as never}
        />,
      ),
    );
    root.querySelector<HTMLButtonElement>("#base-picker-button")!.click();
    while (!document.querySelector('.base-picker-popover [role="option"]'))
      await new Promise((done) => requestAnimationFrame(done));
    const popover = () => document.querySelector<HTMLElement>(".base-picker-popover")!;
    return {
      rowSelector: '[role="option"]',
      rowComponents: ["BranchPickerRowView"],
      scroller: () => popover().querySelector<HTMLElement>(".base-picker-list")!,
      list: popover,
      filter: () => popover().querySelector<HTMLElement>("input")!,
      resizeTarget: popover,
    };
  },
};
export default branchBasePickerCase;
