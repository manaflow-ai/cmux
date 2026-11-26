// l10n-allow-file: test fixture paths and code, not shipped UI.
// A read's card (FileResultCard.tsx), drawn with the diff card's classes (`.cv-edit-diff`), in a column as wide as
// the transcript's. `window.__fileResultCard.measure(size)` draws it at the chat text size `size` and reports its
// header's height (file-result-card-browser.test.ts reads it).
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { FileResultCard } from "../../src/agent-session/acpmux/conversation/FileResultCard";
import { setChatDisplay } from "../../src/agent-session/acpmux/chatDisplay";
// The pane's styles, as its dev entry loads them (acpmux/dev.tsx).
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";

const root = document.getElementById("root")!;
root.style.width = "720px";
const view = createRoot(root);
const read = {
  path: "/home/dev/cmux/src/retry.ts",
  start: 12,
  end: 14,
  code: "export const a = 1;\nexport const b = 2;\nexport const c = 3;",
};

(window as unknown as { __fileResultCard: { measure(size: number): number } }).__fileResultCard = {
  measure(size) {
    setChatDisplay({ "agentPane.display.font.size": size });
    flushSync(() =>
      view.render(<FileResultCard key={size} id={`read-${size}`} card={{ kind: "read", read }} reveal={0} />),
    );
    return document.querySelector(".cv-filepeek > .cv-edit-diff__header")?.getBoundingClientRect().height ?? -1;
  },
};
