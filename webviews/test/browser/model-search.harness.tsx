// The agent pane's compact model menu on Lawrence's machine (src/gallery/fixtures/modelSearch.ts),
// with the pane's own styles, so a real browser lays its search rows out. `?look=flat` draws the
// one-list search version. Each pick lands in `window.picked`.
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createRoot } from "react-dom/client";
import { ModelPicker } from "../../src/agent-session/acpmux/ModelPicker";
import { SOL_SEARCH_CATALOG } from "../../src/gallery/fixtures/modelSearch";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/modelPicker.css";

// The pane's strings, as its dev entry installs them (acpmux/dev.tsx).
globalThis.__cmuxPaneStrings ??= (await import("../../src/agent-session/acpmux/generated/strings.json")).default;

const look = new URLSearchParams(location.search).get("look") === "flat" ? "flat" : "harness";
const picked: unknown[] = [];
(window as unknown as { picked: unknown[] }).picked = picked;

createRoot(document.getElementById("root")!).render(
  <QueryClientProvider client={new QueryClient()}>
    <div className="acpmux" style={{ padding: 16, paddingTop: 520, width: 560 }}>
      <ModelPicker
        catalog={SOL_SEARCH_CATALOG}
        harness="claude"
        model="claude-opus-5-5"
        label="Opus 5.5"
        efforts={[]}
        recents={[]}
        onLand={(model) => picked.push({ model })}
        onEffort={() => undefined}
        onCombo={(combo) => picked.push(combo)}
        quick={{ searchGroups: look, fast: { checked: false, onChange: () => undefined } }}
      />
    </div>
  </QueryClientProvider>,
);
