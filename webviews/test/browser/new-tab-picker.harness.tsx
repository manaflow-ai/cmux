// The New Tab screen as the agent pane lays it out (App.tsx): the screen is the page's one scroller,
// with the template pager under it, and its composer carries the pane's own model chip
// (NewTabComposerChips). The host's actions answer nothing.
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createRoot } from "react-dom/client";
import { noChat } from "../../src/gallery/fixtures/acpmux";
import { NewTabComposerChips } from "../../src/agent-session/acpmux/App";
import { NewTabScreen } from "../../src/agent-session/acpmux/newtab/NewTabScreen";
// The pane's styles, as its dev entry loads them (acpmux/dev.tsx).
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/composerLocation.css";
import "../../src/agent-session/acpmux/modelPicker.css";
import "../../src/agent-session/acpmux/newtab/screen.css";

(window as unknown as { cmuxAcpmuxActions: unknown }).cmuxAcpmuxActions = new Proxy(
  {},
  { get: () => async () => undefined },
);

const noop = () => {};
const client = new QueryClient();
const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%", display: "flex", flexDirection: "column" });

createRoot(root).render(
  <QueryClientProvider client={client}>
    <NewTabScreen
      snapshot={noChat()}
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
    />
    <div className="pager" style={{ flex: "none", height: 40 }} />
  </QueryClientProvider>,
);
