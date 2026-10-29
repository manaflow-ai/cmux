// l10n-allow-file: test fixtures (sample models), not shipped UI.
// A started Claude chat's compact model menu with the pane's own styles: its rail lists Claude
// Code, Codex and OpenCode, and the OpenCode tab holds a single Fork row. A real browser lays it
// out, so the test can check the menu fits its rail and model rows instead of clipping them.
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createRoot } from "react-dom/client";
import { ModelPicker } from "../../src/agent-session/acpmux/ModelPicker";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/modelPicker.css";

// The pane's strings, as its dev entry installs them (acpmux/dev.tsx).
globalThis.__cmuxPaneStrings ??= (await import("../../src/agent-session/acpmux/generated/strings.json")).default;

const models = (names: string[]) => names.map((name) => ({ id: name.toLowerCase().replace(/ /g, "-"), name }));

createRoot(document.getElementById("root")!).render(
  <QueryClientProvider client={new QueryClient()}>
    <div style={{ padding: 16, paddingTop: 520, width: 560 }}>
      <ModelPicker
        catalog={[
          { id: "claude", name: "Claude Code", models: models(["Opus 5.5", "Sonnet 5.5", "Haiku 5.5"]) },
          { id: "codex", name: "Codex", models: models(["GPT-6.1 Sol", "GPT-6 Astra", "GPT-6 Luna"]) },
          { id: "opencode", name: "OpenCode", models: models(["Big Pickle"]) },
        ]}
        harness="claude"
        harnessFixed
        fork={{ to: () => undefined, ready: true }}
        model="opus-5.5"
        label="Opus 5.5"
        efforts={[]}
        recents={[]}
        onLand={() => undefined}
        onEffort={() => undefined}
        quick={{ fast: { checked: false, onChange: () => undefined } }}
      />
    </div>
  </QueryClientProvider>,
);
