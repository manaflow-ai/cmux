// l10n-allow-file: browser measurement fixtures, not shipped UI.
// Imports only modules that predate status verbs: copy this file and its HTML/test to base for
// an identical mounted-browser comparison. The optional gallery import is used only on head.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { Thinking } from "../../src/agent-session/acpmux/conversation/Thinking";
import { THINKING_VERBS, ThinkingVerbsContext } from "../../src/agent-session/acpmux/conversation/thinkingVerbs";
import { setChatDisplay } from "../../src/agent-session/acpmux/chatDisplay";
import { setPaneLanguage } from "../../src/agent-session/acpmux/i18n";
import { pageClocks } from "../../src/ui/pageClock";
import type { ComponentEntry } from "../../src/gallery/format";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";

const root = createRoot(document.getElementById("root")!);
let generation = 0;
let mode = "thinking";

export type StatusVerbsHarness = {
  ready: Promise<void>;
  show(count: number, elapsed?: number): void;
  mode(mode: string, custom?: string): void;
  clocks: typeof pageClocks;
  hidden(value: boolean): void;
  clear(): void;
  gallery(variant: string): Promise<void>;
  theme(name: "light" | "dark"): void;
};

declare global {
  interface Window {
    __statusVerbs: StatusVerbsHarness;
  }
}

window.__statusVerbs = {
  ready: import("../../src/agent-session/acpmux/generated/strings.json").then(({ default: strings }) => {
    globalThis.__cmuxPaneStrings = strings;
    setPaneLanguage("en");
  }),
  show(count, elapsed) {
    generation += 1;
    const since = elapsed === undefined ? Date.now() : 0;
    const now = elapsed === undefined ? Date.now : () => elapsed;
    // Deliberate remount for deterministic timeline samples; the real-clock test mounts only once.
    flushSync(() =>
      root.render(
        <>
          <ThinkingVerbsContext.Provider value={mode === "rotate" ? THINKING_VERBS : undefined}>
            {Array.from({ length: count }, (_, index) => (
              <div
                key={`${generation}-${index}`}
                style={{ width: 360, padding: 12, boxSizing: "border-box", flex: "none" }}
              >
                <Thinking since={since} now={now} verbKey="status-verbs" />
              </div>
            ))}
          </ThinkingVerbsContext.Provider>
        </>,
      ),
    );
  },
  mode(nextMode, custom = "Planning, Reading, Testing") {
    mode = nextMode;
    flushSync(() =>
      setChatDisplay({
        "agentPane.display.statusVerbs.mode": nextMode,
        "agentPane.display.statusVerbs.custom": custom,
      }),
    );
  },
  clocks: pageClocks,
  hidden(value) {
    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      value: value ? "hidden" : "visible",
    });
    document.dispatchEvent(new Event("visibilitychange"));
  },
  clear() {
    flushSync(() => root.render(null));
  },
  async gallery(variant) {
    const url = "/src/agent-session/acpmux/conversation/StatusVerbs.gallery.tsx";
    const entry: ComponentEntry<{ variant: string }> = (await import(/* @vite-ignore */ url)).default;
    await entry.styles?.();
    const Fixture = await entry.load();
    flushSync(() =>
      root.render(
        <div data-status-verbs-gallery style={{ width: "100%" }}>
          <Fixture key={variant} variant={variant} />
        </div>,
      ),
    );
  },
  theme(name) {
    document.documentElement.style.colorScheme = name;
    document.documentElement.style.setProperty("--cmux-text", name === "dark" ? "#ececec" : "#1c1c1c");
    document.body.style.background = name === "dark" ? "#181818" : "#fafafa";
  },
};
window.__statusVerbs.theme("dark");
