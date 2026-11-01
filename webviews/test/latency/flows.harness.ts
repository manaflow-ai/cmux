// Existing production pane, reducer, mock transport and paged history; no substitute UI.
import { MockAcpmuxSocket } from "../../src/agent-session/acpmux/mock";
import { WORKED_SESSION } from "../../src/agent-session/acpmux/mockFixture";
import { setChatDisplay, MINIMAP_KEY } from "../../src/agent-session/acpmux/chatDisplay";
import type {} from "../../src/experiments/experiment";

// CHAT SWITCH MOTION: `switch=<arm>` runs the pane under that arm of the chat-switch-motion
// experiment (chatSwitch.ts), set before the pane mounts, as the gallery's stage sets it.
const switchArm = new URLSearchParams(location.search).get("switch");
if (switchArm) globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, "chat-switch-motion": switchArm };

await import("../../src/agent-session/acpmux/dev");

async function until(ready: () => boolean): Promise<void> {
  const deadline = performance.now() + 25_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error("production chat flow fixture did not become ready");
    await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
  }
}

await until(() => !!window.cmuxAcpmuxActions?.["chat.send"] && !!window.cmuxAcpmuxDebug && !!MockAcpmuxSocket.live);
const turns = Number(new URLSearchParams(location.search).get("turns") ?? 0);
const resident = new URLSearchParams(location.search).has("resident");
// 100 turns: a typical chat for the rail hover sweep (test/latency/rail-sweep.ts).
if (turns !== 0 && turns !== 100 && turns !== 3000) throw new Error("unsupported flow fixture size");
if (resident && turns === 0) throw new Error("resident flow fixture requires a turn count");
const sessionId = turns && !resident ? MockAcpmuxSocket.live!.seedLoadSession(turns) : WORKED_SESSION;
window.cmuxAcpmuxBridge!.applyHeaderState!({ inspector: true, version: 2 });
// The resident rail adapter measures compact-arm entries (`.acpmux-minimap__entry`).
// The full arm intentionally renders a different minimap and has no entry ticks.
setChatDisplay({ [MINIMAP_KEY]: "compact" });

const flows = {
  sessionId,
  turns,
  resident,
  restoreChat() {
    window.cmuxAcpmuxDebug!.selectSession(sessionId);
  },
  /** Another chat of the mock daemon (mockFixture.ts), for the chat switch case. */
  openOtherChat() {
    window.cmuxAcpmuxDebug!.selectSession("mock-ci-cache");
  },
  openNewTab() {
    // Same context event used when the native Cmd-T action adopts a prewarmed page. This
    // measures the web UI's adoption-to-paint, not the native tab creation or host IPC.
    window.dispatchEvent(
      new CustomEvent("acpmux-newtab-adopt", {
        detail: { kind: "agent", hotkeys: {}, home: "/home/dev", projects: ["~/code/cmux"], template: "default" },
      }),
    );
  },
};
(window as Window & { __latencyFlows?: typeof flows }).__latencyFlows = flows;
flows.restoreChat();
await until(
  () =>
    window.cmuxAcpmuxDebug!.chatState().sessionId === sessionId &&
    [...document.querySelectorAll(".cv-user__bubble")].some((node) =>
      turns && !resident ? node.textContent?.startsWith(`Turn ${turns - 1}:`) : !!node.textContent?.trim(),
    ),
);
// The resident case isolates virtual transcript work at 3,000 turns; the other long fixture
// keeps the mock daemon's normal history paging. seedRows uses the existing mixed-row fixture
// (three rows per turn), not an alternate transcript component.
if (resident) {
  await window.cmuxAcpmuxDebug!.seedRows(turns * 3);
  await until(() => document.querySelector(".acpmux-minimap__entry")?.getAttribute("aria-setsize") === String(turns));
}
// GLASS: the pane over a picture with the glass in one mode, to compare the frame cost of each
// (design/glass.md in leo-workspace): plain (blur), lens, lens-flat (the lens with no gloss),
// prism (Spectrum with full gloss) and svg (Chromium's feDisplacementMap backdrop, svgRefraction.ts).
const glass = new URLSearchParams(location.search).get("glass");
if (glass) await installGlass(glass);
document.documentElement.dataset.latencyFlowsReady = "true";

/** A synthetic, colourful still: the picture behind the window glass, as the host sends it. */
function picture(width: number, height: number): string {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d")!;
  const sky = context.createLinearGradient(0, 0, width, height);
  sky.addColorStop(0, "#1b2a6b");
  sky.addColorStop(0.5, "#b0306a");
  sky.addColorStop(1, "#f2a541");
  context.fillStyle = sky;
  context.fillRect(0, 0, width, height);
  for (let index = 0; index < 40; index++) {
    context.fillStyle = `hsl(${(index * 47) % 360} 80% 60% / 0.55)`;
    context.beginPath();
    context.arc((index * 197) % width, (index * 131) % height, 30 + ((index * 17) % 90), 0, Math.PI * 2);
    context.fill();
  }
  return canvas.toDataURL("image/jpeg", 0.9);
}

async function installGlass(mode: string): Promise<void> {
  const known = ["plain", "lens", "lens-flat", "prism", "svg"];
  if (!known.includes(mode)) throw new Error(`unsupported glass mode ${mode}`);
  const root = document.documentElement;
  const { installBackdropFallback } = await import("../../src/ui/glass/glassState");
  const { installGlassLens } = await import("../../src/ui/glass/lens");
  installBackdropFallback(window);
  const image = picture(1024, 640);
  root.style.setProperty("--cmux-surface-background", "transparent");
  root.style.setProperty("background", `url("${image}") 0 0 / 100vw 100vh no-repeat fixed`, "important");
  root.setAttribute(
    "data-glass",
    mode === "prism" ? "spectrum" : mode === "lens" || mode === "lens-flat" ? "lens" : "plain",
  );
  if (mode === "lens-flat") root.style.setProperty("--glass-gloss", "0");
  if (mode === "prism") root.style.setProperty("--glass-gloss", "1");
  if (mode === "svg") {
    const { installSvgRefraction } = await import("../../src/ui/glass/svgRefraction");
    installSvgRefraction(document);
  }
  installGlassLens(document);
  (window as Window & { cmuxTheme?: { backdrop?: (partial: unknown) => void } }).cmuxTheme?.backdrop?.({
    image,
    key: "latency-glass",
    rect: { x: 0, y: 0, width: root.clientWidth, height: root.clientHeight },
    blur: 0,
    tint: "rgba(0, 0, 0, 0.18)",
  });
  if (mode === "lens" || mode === "lens-flat" || mode === "prism") {
    // The lens needs WebGL: a browser without it would measure CSS glass under the lens's name.
    const deadline = performance.now() + 8_000;
    while (!root.hasAttribute("data-glass-lens")) {
      if (performance.now() > deadline) throw new Error(`glass=${mode}: the WebGL lens did not start in this browser`);
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
    }
  }
}
