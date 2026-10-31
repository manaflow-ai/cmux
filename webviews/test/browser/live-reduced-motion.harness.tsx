// l10n-allow-file: synthetic streaming reply fixture.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { RevealedMarkdown, revealFrames } from "../../src/agent-session/acpmux/conversation/RevealedMarkdown";
import "../../src/agent-session/acpmux/conversation/conversation.css";

const pending = new Map<number, (now: number) => void>();
let handle = 0;
let now = 0;
revealFrames.request = (callback) => {
  pending.set(++handle, callback);
  return handle;
};
revealFrames.cancel = (id) => {
  pending.delete(id);
};
const root = createRoot(document.getElementById("root")!);
const render = (text: string) => flushSync(() => root.render(<RevealedMarkdown text={text} streaming />));
const sample = () => ({
  text: document.querySelector(".cv-md .cv-md")?.textContent ?? "",
  fresh: document.querySelectorAll(".cv-fresh").length,
  pending: pending.size,
});
const motion = {
  render,
  sample,
  step() {
    const callbacks = [...pending.values()];
    pending.clear();
    now += 16;
    flushSync(() => {
      for (const callback of callbacks) callback(now);
    });
    return sample();
  },
  nextPaint() {
    return new Promise<ReturnType<typeof sample>>((resolve) => requestAnimationFrame(() => resolve(sample())));
  },
  unmount() {
    flushSync(() => root.unmount());
  },
};
declare global {
  interface Window {
    liveReducedMotion: typeof motion;
  }
}
window.liveReducedMotion = motion;
render("");
