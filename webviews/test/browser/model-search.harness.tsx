// The agent pane's compact model menu on Lawrence's machine (src/gallery/fixtures/modelSearch.ts),
// with the pane's own styles, so a real browser lays its search rows out. `?look=flat` draws the
// one-list search version, `?catalog=deepseek` OpenCode's DeepSeek list. Each pick lands in `window.picked`.
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createRoot } from "react-dom/client";
import { ModelPicker } from "../../src/agent-session/acpmux/ModelPicker";
import { DEEPSEEK_SEARCH_CATALOG, SOL_SEARCH_CATALOG } from "../../src/gallery/fixtures/modelSearch";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/modelPicker.css";

// The pane's strings, as its dev entry installs them (acpmux/dev.tsx).
globalThis.__cmuxPaneStrings ??= (await import("../../src/agent-session/acpmux/generated/strings.json")).default;

const params = new URLSearchParams(location.search);
const look = params.get("look") === "flat" ? "flat" : "harness";
// `?catalog=deepseek` draws OpenCode's DeepSeek list (Lawrence 2026-11-05); `?theme=light|dark` pins the look.
const catalog = params.get("catalog") === "deepseek" ? DEEPSEEK_SEARCH_CATALOG : SOL_SEARCH_CATALOG;
const theme = params.get("theme");
if (theme === "light" || theme === "dark") {
  // The page theme the app hands a light or dark pane (WebTheme.swift), with an opaque menu surface
  // in place of the native glass, so screenshots read as the app's menu.
  const root = document.documentElement;
  root.dataset.theme = theme;
  root.style.colorScheme = theme;
  root.style.setProperty("--cmux-text", theme === "light" ? "#1d1d1f" : "#ececec");
  root.style.setProperty("--cmux-popup-surface", theme === "light" ? "#f7f7f7" : "#262626");
}
const picked: unknown[] = [];
(window as unknown as { picked: unknown[] }).picked = picked;

createRoot(document.getElementById("root")!).render(
  <QueryClientProvider client={new QueryClient()}>
    <div className="acpmux" style={{ padding: 16, paddingTop: 520, width: 560 }}>
      <ModelPicker
        catalog={catalog}
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
