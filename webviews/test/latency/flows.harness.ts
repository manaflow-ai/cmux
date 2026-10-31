// Existing production pane, reducer, mock transport and paged history; no substitute UI.
import { MockAcpmuxSocket } from "../../src/agent-session/acpmux/mock";
import { WORKED_SESSION } from "../../src/agent-session/acpmux/mockFixture";
import { setChatDisplay, MINIMAP_KEY } from "../../src/agent-session/acpmux/chatDisplay";

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
document.documentElement.dataset.latencyFlowsReady = "true";
