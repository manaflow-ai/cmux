// l10n-allow-file: browser measurement fixture, not shipped UI.
// The composer's context ring between readings (context-ring-motion-browser.test.ts). Imports only
// modules that predate the ring's motion, so this file, its HTML and the test run on base too.
// `window.ring({ chat, used, size, motion, look })` renders the ring in one frame.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { ContextRing } from "../../src/agent-session/acpmux/ComposerPickers";
import strings from "../../src/agent-session/acpmux/generated/strings.json";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/composerFooterShared.css";

globalThis.__cmuxPaneStrings = { en: strings.en };
document.documentElement.style.setProperty("--agent-text", "#f5f5f1");
document.documentElement.style.setProperty("--agent-muted", "#c9c9c4");
document.body.style.background = "#202124";
document.body.style.color = "#c9c9c4";
document.body.style.margin = "0";

type Reading = { chat?: string; used?: number; size?: number; motion?: string; look?: string };
const root = createRoot(document.getElementById("root")!);
(window as unknown as { ring(reading: Reading): void }).ring = ({ chat, used, size, motion, look }) => {
  globalThis.cmuxExperiments = {
    ...(motion ? { "context-ring-motion": motion } : {}),
    ...(look ? { "context-ring-look": look } : {}),
  };
  flushSync(() => root.render(<ContextRing chat={chat} used={used} size={size} />));
};
