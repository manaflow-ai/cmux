// l10n-allow-file: test fixtures (sample models), not shipped UI.
// The agent pane's compact model menu with the pane's own styles, so a real browser lays out its
// rows, rail, search field, Effort submenu and Fast mode switch. `?density=NAME` draws a gallery
// density version (src/gallery/fixtures/modelMenuDensity.ts).
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createRoot } from "react-dom/client";
import { ModelPicker } from "../../src/agent-session/acpmux/ModelPicker";
import { DENSITY_CSS, type MenuDensity } from "../../src/gallery/fixtures/modelMenuDensity";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/modelPicker.css";

// The pane's strings, as its dev entry installs them (acpmux/dev.tsx).
globalThis.__cmuxPaneStrings ??= (await import("../../src/agent-session/acpmux/generated/strings.json")).default;

const density = (new URLSearchParams(location.search).get("density") ?? "native") as MenuDensity;
const models = (names: string[]) => names.map((name) => ({ id: name.toLowerCase().replace(/ /g, "-"), name }));

createRoot(document.getElementById("root")!).render(
  <QueryClientProvider client={new QueryClient()}>
    <style>{DENSITY_CSS[density]}</style>
    <div style={{ padding: 16, paddingTop: 520, width: 560 }}>
      <ModelPicker
        catalog={[
          { id: "claude", name: "Claude Code", models: models(["Opus 5.5", "Sonnet 5.5", "Haiku 5.5"]) },
          { id: "codex", name: "Codex", models: models(["GPT-6.1 Sol", "GPT-6 Astra", "GPT-6 Luna"]) },
          { id: "opencode", name: "OpenCode", models: models(["Big Pickle"]) },
        ]}
        harness="claude"
        model="opus-5.5"
        label="Opus 5.5"
        efforts={[]}
        recents={[]}
        onLand={() => undefined}
        onEffort={() => undefined}
        quick={{
          effort: {
            levels: ["Low", "Medium", "High", "Extra High", "Max", "Ultracode"].map((name) => ({
              id: name.toLowerCase().replace(/ /g, ""),
              name,
            })),
            current: "high",
            onPick: () => undefined,
          },
          fast: { checked: false, onChange: () => undefined },
        }}
      />
    </div>
  </QueryClientProvider>,
);
