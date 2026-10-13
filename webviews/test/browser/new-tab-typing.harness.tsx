// Both New Tab screens as the agent pane renders them (App.tsx): a host update (a snapshot, the
// window taking focus) renders the page again with new callbacks (`newTabScreenActions` closes over
// that state). `window.rerenderHost()` is such an update.
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { noChat } from "../../src/gallery/fixtures/acpmux";
import { NewTabScreen } from "../../src/agent-session/acpmux/newtab/NewTabScreen";
import { NewTabPage } from "../../src/agent-session/acpmux/NewTabPage";

declare global {
  interface Window {
    rerenderHost?: () => void;
  }
}

const classic = new URLSearchParams(location.search).get("screen") === "classic";
const snapshot = noChat();
const noop = () => {};

function Host() {
  const [update, setUpdate] = useState(0);
  window.rerenderHost = () => flushSync(() => setUpdate((count) => count + 1));
  const ready = (token: string) => void [token, update];
  return classic ? (
    <NewTabPage
      snapshot={snapshot}
      cwd="/Users/you/src/app"
      inputToken="opening-1"
      onInputReady={(token) => ready(token)}
      onSubmit={noop}
      onOpenSession={noop}
      onShowAll={noop}
    />
  ) : (
    <NewTabScreen
      snapshot={snapshot}
      lastAgent="claude"
      cwd="/Users/you/src/app"
      inputToken="opening-1"
      onInputReady={(token) => ready(token)}
      onAsk={noop}
      onOpen={noop}
      onSearch={noop}
      onShell={noop}
      onJump={noop}
      onOpenSession={noop}
      onShowAll={noop}
    />
  );
}

createRoot(document.getElementById("root")!).render(<Host />);
