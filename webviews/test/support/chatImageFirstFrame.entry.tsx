// The page half of chat-image-first-frame-browser.test.ts: the real UserBubble, mounted from an
// acpmux prompt record read through the pane's own parser, with its image's bytes late.
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { UserBubble } from "../../src/agent-session/acpmux/conversation/UserBubble";
import { TurnActionsContext } from "../../src/agent-session/acpmux/conversation/turnActions";
import { clearImageEntries } from "../../src/agent-session/acpmux/conversation/imageEntries";
import { recordedPromptParts } from "../../src/agent-session/acpmux/inlinePrompt";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";

type Heights = { first: number; painted: number; loaded: number; imageLoaded: boolean };

/// Mounts the bubble for `msg` three times: fresh, re-mounted (the virtual list scrolling it back),
/// and with every image the pane held forgotten (an app restart). Each pass reads the bubble's
/// height on the frame that mounts it, on its first painted frame, and once its image has drawn;
/// the image's bytes come `delayMs` late, as a read over acpmux's socket does.
async function measure(msg: any, delayMs: number): Promise<Heights[]> {
  // The screenshot's bytes: 1280x228, the shape of Leo's "Checking back in 19 min." capture.
  const canvas = document.createElement("canvas");
  canvas.width = 1280;
  canvas.height = 228;
  const ink = canvas.getContext("2d")!;
  ink.fillStyle = "#1d1b26";
  ink.fillRect(0, 0, 1280, 228);
  const dataUrl = canvas.toDataURL("image/png");
  // fixed-wait: the late bytes are the behavior under test; nothing waits on this timer, the page waits for the image to draw.
  const promptImage = () => new Promise<string>((resolve) => setTimeout(() => resolve(dataUrl), delayMs));
  const row = {
    id: "user-w4",
    version: 1,
    at: 1,
    kind: "user_message",
    text: msg.text,
    images: msg.images,
    inlineParts: recordedPromptParts(msg),
  } as unknown as AcpmuxRow;
  const host = document.getElementById("chat")!;
  const frame = () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
  const height = () => host.getBoundingClientRect().height;
  const drawn = () => {
    const img = host.querySelector<HTMLImageElement>(".cv-user__inline-image img, .cv-user__images img");
    return Boolean(img?.complete && img.naturalWidth);
  };
  const out: Heights[] = [];
  for (const pass of ["fresh", "remount", "restart"]) {
    if (pass === "restart") clearImageEntries();
    const slot = document.createElement("div");
    slot.className = "cv-user";
    host.replaceChildren(slot);
    const root = createRoot(slot);
    flushSync(() =>
      root.render(
        <TurnActionsContext.Provider value={{ promptImage }}>
          <UserBubble row={row} text={msg.text} />
        </TurnActionsContext.Provider>,
      ),
    );
    const first = height();
    await frame();
    const painted = height();
    const deadline = performance.now() + 5000;
    while (!drawn() && performance.now() < deadline) await frame();
    await frame();
    await frame();
    out.push({ first, painted, loaded: height(), imageLoaded: drawn() });
    root.unmount();
  }
  return out;
}

(window as unknown as Record<string, unknown>).measureChatImage = measure;
