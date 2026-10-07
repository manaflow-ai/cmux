// l10n-allow-file: gallery fixtures, not shipped UI.
import { bridgePageEntry, type BridgePageVariant } from "../../gallery/format";
import type { Binding } from "./types";
function fixture(count: number): BridgePageVariant {
  const bindings: Binding[] = Array.from({ length: count }, (_, i) => ({
    id: i,
    key: `cmd+${i % 10}`,
    display: `⌘${i % 10}`,
    command: `sample.action${i}`,
    title:
      count > 4
        ? `Open a workspace with a long project name and select terminal ${i + 1}`
        : ["New workspace", "Open browser", "Find in terminal", "Show settings"][i]!,
    when: i % 2 ? "terminalFocus" : null,
    source: i % 3 ? "default" : "user",
    conflicts: [],
  }));
  return {
    streams: ["cmux.keybindings.changed", "cmux.keybindings.recorded"],
    replies: { "cmux.keybindings.list": { bindings } },
  };
}
export default bridgePageEntry({
  id: "pages.keybindings",
  title: "Keyboard shortcuts",
  area: "Pages",
  page: "keybindings",
  covers: ["page:cmux.keybindings", "pages/keybindings/KeybindingsPage.tsx"],
  variants: {
    empty: fixture(0),
    loaded: fixture(4),
    "long-content": fixture(40),
    error: {
      ...fixture(0),
      failures: {
        "cmux.keybindings.list": { code: "cmux.page.failed", message: "Sample owner is unavailable. Try again." },
      },
    },
    loading: { ...fixture(0), pending: ["cmux.keybindings.list"] },
  },
});
