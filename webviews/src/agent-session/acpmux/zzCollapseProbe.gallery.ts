// l10n-allow-file: temporary probe, not committed.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { chat } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import { COMPOSER_EDITOR } from "./composerSelectors";

const EDITOR = { selector: COMPOSER_EDITOR };
const TRUSTED = "~/code/cmux";
const fresh = chat([]);
const snapshot = { ...fresh, summary: { ...fresh.summary!, cwd: TRUSTED } };
const pause = (ms: number) => new Promise((r) => setTimeout(r, ms));

function probe(lines: number, mode: "typed" | "pasted") {
  return async (ctx: PlayContext) => {
    const doc = ctx.document;
    const win = doc.defaultView!;
    await ctx.type("first question", EDITOR);
    await ctx.press("Enter");
    await ctx.waitFor(() => !doc.querySelector(".acpmux-cancel"), { capMs: 30_000 });
    await pause(400);
    const field = doc.querySelector<HTMLElement>(COMPOSER_EDITOR)!;
    field.focus();
    if (mode === "typed") {
      for (let i = 1; i <= lines; i += 1) {
        // eslint-disable-next-line @typescript-eslint/no-deprecated
        doc.execCommand("insertText", false, `draft line ${i} of the tall message`);
        if (i < lines) await ctx.press("Shift+Enter");
      }
    } else {
      const text = Array.from({ length: lines }, (_, i) => `draft line ${i + 1} of the tall message`).join("\n");
      const data = new win.DataTransfer();
      data.setData("text/plain", text);
      field.dispatchEvent(new win.ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    }
    await pause(1200);
    const box = doc.querySelector<HTMLElement>(".acpmux-composer-box")!;
    const prompt = () => doc.querySelector(".acpmux-composer-prompt")?.textContent?.length ?? 0;
    const frames: { t: number; h: number; text: number }[] = [];
    const longs: unknown[] = [];
    const po = new win.PerformanceObserver((list) => {
      for (const e of list.getEntries() as any[])
        longs.push({
          at: Math.round(e.startTime - start),
          d: Math.round(e.duration),
          block: Math.round(e.blockingDuration ?? 0),
          render: Math.round((e.renderStart ?? 0) - e.startTime),
          layout: Math.round((e.styleAndLayoutStart ?? 0) - e.startTime),
          scripts: (e.scripts ?? [])
            .filter((x: any) => x.duration > 5)
            .map(
              (x: any) =>
                `${x.invoker}|${x.sourceFunctionName}|${String(x.sourceURL).split("/").pop()}|${Math.round(x.duration)}ms|forced${Math.round(x.forcedStyleAndLayoutDuration)}`,
            ),
        });
    });
    try {
      po.observe({ type: "long-animation-frame", buffered: false });
    } catch {
      po.observe({ type: "longtask", buffered: false });
    }
    const before = { h: box.getBoundingClientRect().height, text: prompt() };
    let start = 0;
    const done = new Promise<void>((resolve) => {
      const tick = (at: number) => {
        frames.push({ t: Math.round(at - start), h: Math.round(box.getBoundingClientRect().height), text: prompt() });
        if (at - start < 1500) win.requestAnimationFrame(tick);
        else resolve();
      };
      win.requestAnimationFrame(tick);
    });
    console.profile("send");
    start = win.performance.now();
    const ev = { key: "Enter", code: "Enter", bubbles: true, cancelable: true };
    field.dispatchEvent(new win.KeyboardEvent("keydown", ev));
    const syncMs = win.performance.now() - start;
    field.dispatchEvent(new win.KeyboardEvent("keyup", ev));
    setTimeout(() => console.profileEnd("send"), 400);
    await done;
    po.disconnect();
    const cleared = frames.find((f) => f.text < before.text / 2 || f.text === 0);
    const finalH = frames.at(-1)!.h;
    const rest = frames.find((f, i) => frames.slice(i).every((g) => Math.abs(g.h - finalH) <= 1));
    const result = {
      lines,
      mode,
      beforeH: Math.round(before.h),
      beforeText: before.text,
      finalH,
      syncKeydownMs: Math.round(syncMs),
      clearedMs: cleared?.t ?? -1,
      restMs: rest?.t ?? -1,
      longFrames: longs,
      heights: frames
        .slice(0, 30)
        .map((f) => `${f.t}:${f.h}`)
        .join(" "),
    };
    doc.documentElement.dataset.probe = JSON.stringify(result);
  };
}

const variants: Record<string, AgentPaneVariant> = {};
for (const lines of [1, 5, 15, 40])
  variants[`typed-${lines}`] = {
    note: "probe",
    ready: { transport: "mock", newSession: true, cwd: TRUSTED },
    snapshot,
    play: probe(lines, "typed"),
  };
for (const lines of [15, 40, 200])
  variants[`pasted-${lines}`] = {
    note: "probe",
    ready: { transport: "mock", newSession: true, cwd: TRUSTED },
    snapshot,
    play: probe(lines, "pasted"),
  };

export default agentPaneEntry({
  id: "agent-pane.zz-collapse-probe",
  title: "probe",
  area: "Agent pane",
  height: 640,
  widths: { normal: 900 },
  checks: {
    layoutShiftMax: { value: 1, reason: "A temporary probe that times the collapse, not its shift." },
    longFrameFailMs: { value: 100000, reason: "A temporary probe that records long frames itself." },
  },
  covers: ["agent-session/acpmux/Composer.tsx"],
  variants,
});
