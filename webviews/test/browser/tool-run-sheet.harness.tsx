// l10n-allow-file: synthetic before/after browser fixture.
import { createRoot } from "react-dom/client";
import type { CSSProperties } from "react";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/glass/glass.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import { ToolRows } from "../../src/agent-session/acpmux/conversation/TurnRows";
import { mixedToolRunFixture } from "../../src/agent-session/acpmux/conversation/mixedToolRunFixture";
import strings from "../../src/agent-session/acpmux/generated/strings.json";

globalThis.__cmuxPaneStrings = { en: strings.en };
document.documentElement.dataset.cmuxMotion = "off";
const theme = new URLSearchParams(location.search).get("theme") === "light" ? "light" : "dark";
createRoot(document.getElementById("root")!).render(
  <main className="acpmux-shell" data-theme={theme} style={{
    "--agent-page-bg": theme === "dark" ? "#202124" : "#f7f7f2",
    "--agent-text": theme === "dark" ? "#f5f5f1" : "#242420",
    "--font-ui": "system-ui", padding: 24, width: "100%", boxSizing: "border-box",
  } as CSSProperties}>
    <div data-sheet-fixture>
      <ToolRows row={{ id: "sheet-measurement", version: 1, kind: "activity", at: 1,
        foldRun: true, items: mixedToolRunFixture() }} />
    </div>
  </main>,
);
