// The New Tab screen as the agent pane lays it out (App.tsx): the screen is the page's one scroller,
// with the template pager under it, and its composer carries the pane's own model chip
// (NewTabComposerChips). The host's actions answer nothing. `?reported` gives the chips a session
// that reported its reasoning levels and access modes, so the model menu's Effort submenu and the
// access menu show. `?template=cards` draws the Cards page, the app's default, with Claude Code's
// split (the mode and the one model button in the quiet row under the box); with no template it
// draws Default, the stage layout
// (the composer at the foot of the page).
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createRoot } from "react-dom/client";
import { noChat } from "../../src/gallery/fixtures/acpmux";
import { NewTabComposerChips } from "../../src/agent-session/acpmux/App";
import { NewTabScreen } from "../../src/agent-session/acpmux/newtab/NewTabScreen";
import type { ScreenTemplate } from "../../src/agent-session/acpmux/newtab/templates";
// The pane's styles, as its dev entry loads them (acpmux/dev.tsx).
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/composerLocation.css";
import "../../src/agent-session/acpmux/composerFooterShared.css";
import "../../src/agent-session/acpmux/modelPicker.css";
import "../../src/agent-session/acpmux/newtab/screen.css";

(window as unknown as { cmuxAcpmuxActions: unknown }).cmuxAcpmuxActions = new Proxy(
  {},
  { get: () => async () => undefined },
);

const noop = () => {};
const query = new URLSearchParams(location.search);
const reported = query.has("reported");
const template = (query.get("template") ?? undefined) as ScreenTemplate | undefined;
const snapshot = noChat(
  [],
  reported
    ? {
        summary: {
          sessionId: "s-reported",
          harness: "claude",
          model: "default",
          turnCount: 0,
          configOptions: [
            {
              id: "effort",
              name: "Effort",
              category: "thought_level",
              currentValue: "high",
              options: ["low", "medium", "high"].map((value) => ({ value, name: value })),
            },
          ],
          modes: {
            currentModeId: "default",
            availableModes: [
              { id: "default", name: "Ask before edits" },
              { id: "acceptEdits", name: "Edit automatically" },
              { id: "plan", name: "Plan" },
              { id: "bypassPermissions", name: "Bypass permissions" },
            ],
          },
        },
      }
    : {},
);
const client = new QueryClient();
const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%", display: "flex", flexDirection: "column" });

createRoot(root).render(
  <QueryClientProvider client={client}>
    <NewTabScreen
      {...(template ? { template } : {})}
      snapshot={snapshot}
      lastAgent="claude"
      cwd="/Users/you/src/app"
      inputToken="opening-1"
      chips={NewTabComposerChips}
      onAsk={noop}
      onOpen={noop}
      onSearch={noop}
      onShell={noop}
      onJump={noop}
      onOpenSession={noop}
      onShowAll={noop}
      {...(query.has("crowdedSuggestions")
        ? {
            onCreate: noop,
            omnibar: {
              tabs: [],
              workspaces: [],
              sessions: [],
              folders: [],
              commands: [],
              history: Array.from({ length: 4 }, (_, index) => ({
                url: `https://example.com/project-${index}`,
                title: `Project notes ${index + 1}`,
              })),
            },
          }
        : {})}
    />
    <div className="pager" style={{ flex: "none", height: 40 }} />
  </QueryClientProvider>,
);
