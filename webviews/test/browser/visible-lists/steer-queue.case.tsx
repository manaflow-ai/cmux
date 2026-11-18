// l10n-allow-file: test fixture chats, not shipped UI.
// The steer queue (acpmux/steerQueue/SteerQueue.tsx) with N chats, its rows of different heights: a
// chat the person stepped into has a third line (its `said` line), and a step the person takes adds
// that line to a row after it mounted. `?look=compact` draws one line per chat, with compact padding.
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import type { SteerItem, SteerReason } from "../../../src/agent-session/acpmux/steerQueue/model";
import {
  SteerQueue,
  type SteerActions,
  type SteerQueueLook,
} from "../../../src/agent-session/acpmux/steerQueue/SteerQueue";
import "../../../src/agent-session/acpmux/styles.css";
import type { VisibleListCase } from "./case";
import { applyCaseScale } from "./scale";

const NOW = Date.parse("2026-11-18T12:00:00Z");
const REASONS: SteerReason[] = ["ask", "failed", "stalled", "review", "running"];

function steerItems(n: number): SteerItem[] {
  return Array.from({ length: n }, (_, index) => ({
    sessionId: `s-${index}`,
    title: `Chat ${String(index).padStart(3, "0")}`,
    reason: REASONS[index % REASONS.length]!,
    line: `Step ${index} of the chat`,
    at: NOW - (index + 1) * 60_000,
    running: index % 5 === 4,
    // Every fourth chat has a step of the person's newer than its own: its row says so.
    last: index % 4 === 1 ? { sessionId: `s-${index}`, act: "steer", text: "go on", at: NOW - 30_000 } : undefined,
  }));
}

// A step stays under way, so the row it was taken in keeps its `said` line.
const pending = () => new Promise<never>(() => {});
const actions: SteerActions = { steer: pending, redirect: pending, stop: pending, fork: pending, open: pending };

const steerQueueCase: VisibleListCase = {
  mount(root, n) {
    applyCaseScale();
    const look = (new URLSearchParams(location.search).get("look") ?? "rows") as SteerQueueLook;
    root.className = "acpmux-shell";
    root.style.cssText = "position: relative; height: 520px; width: 560px;";
    flushSync(() =>
      createRoot(root).render(
        <SteerQueue items={steerItems(n)} now={NOW} actions={actions} onClose={() => undefined} look={look} />,
      ),
    );
    const list = () => root.querySelector<HTMLElement>("[role='listbox']")!;
    return {
      rowSelector: '[role="option"]',
      rowComponents: ["ListboxRow", "SteerRow"],
      scroller: list,
      list,
      keyTarget: () => root.querySelector<HTMLElement>(".acpmux-steer-field")!,
    };
  },
};
export default steerQueueCase;
