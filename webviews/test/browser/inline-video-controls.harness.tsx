// Browser harness for test/inline-video-controls-browser.test.ts: a video in a reply (chips/ReplyMedia.tsx
// `MediaPlayer`) with the pane's stylesheets, playing the gallery's recording. `?tool` puts it in a
// tool's output (conversation.css `.cv-tool-images`, a smaller frame); `?width=N` narrows the column.
import { createRoot } from "react-dom/client";
import { setPaneLanguage } from "../../src/agent-session/acpmux/i18n";
import { MediaPlayer } from "../../src/agent-session/acpmux/chips/ReplyMedia";
import { setChipHost } from "../../src/agent-session/acpmux/chips/host";
import { LOGIN_TESTS_MP4 } from "../../src/gallery/fixtures/toolImages";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/glass/glass.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/chips/chips.css";

globalThis.__cmuxPaneStrings ??= (await import("../../src/agent-session/acpmux/generated/strings.json")).default;
setPaneLanguage("en");
// Open in tab asks the host; here nothing answers.
const actions: string[] = [];
Object.assign(window, { __videoActions: actions });
setChipHost(async (method) => {
  actions.push(method);
  return undefined;
});

const params = new URLSearchParams(location.search);
document.body.style.margin = "0";
const root = document.getElementById("root")!;
root.style.width = `${Number(params.get("width") ?? 640)}px`;
root.style.padding = "16px";
const height = Number(params.get("height"));
if (height > 0) {
  const style = document.createElement("style");
  style.textContent = `.cv-media video { width: 400px; height: ${height}px; object-fit: contain; }`;
  document.head.append(style);
}
const player = (
  <MediaPlayer
    src={`data:video/mp4;base64,${LOGIN_TESTS_MP4}`}
    source="/Users/you/src/atlas-web/out/login-tests.mp4"
    kind="video"
    name="login-tests.mp4"
    onError={() => {}}
  />
);
createRoot(root).render(params.has("tool") ? <div className="cv-tool-images">{player}</div> : player);
