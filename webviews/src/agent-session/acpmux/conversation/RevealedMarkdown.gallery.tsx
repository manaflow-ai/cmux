// l10n-allow-file: deterministic gallery fixture labels, not shipped copy.
// Settled prose stays drawn while the same reply refreshes; only new streaming text may reveal.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { RevealedMarkdown } from "./RevealedMarkdown";

type Variant = "historical-refresh" | "truncated-reconnect" | "live-arrival";
const HISTORY = "The earlier answer stays readable while the recent page refreshes.";
const SUFFIX = "Already visible text stays on screen.";
const COMPLETE = `The full historical reply is available.\n\n${SUFFIX}`;
const LIVE = "New words arrive in this reply while the earlier answer stays in place.";
const rendered = (text: string) => text.replaceAll("\n", "");

function RefreshFixture({ variant }: { variant: Variant }) {
  const [step, setStep] = useState(0);
  const live = variant === "live-arrival";
  const text = live
    ? step === 0
      ? ""
      : LIVE
    : variant === "historical-refresh"
      ? step === 0
        ? SUFFIX
        : COMPLETE
      : step === 1
        ? "The full historical reply"
        : COMPLETE;
  return (
    <main data-refresh-fixture style={{ padding: 24, maxWidth: 640 }}>
      <button type="button" className="ui-button" onClick={() => setStep((value) => value + 1)}>
        Advance snapshot
      </button>
      <div className="cv-message" data-refresh-row="history">
        <RevealedMarkdown text={HISTORY} streaming={false} artifactIdentity="refresh-history" />
      </div>
      <div className="cv-message" data-refresh-row="reply" data-snapshot-step={step}>
        <RevealedMarkdown text={text} streaming={live && step < 2} artifactIdentity="refresh-reply" />
      </div>
    </main>
  );
}

// Observe the transition, not just the settled screenshot: a missing body that returns before
// click() settles still fails. The invariant concerns the visible prose, not fixture controls.
async function advance(ctx: PlayContext, historical: boolean, expected: string) {
  const history = ctx.find({ selector: '[data-refresh-row="history"] .cv-md' });
  const reply = ctx.find({ selector: '[data-refresh-row="reply"] .cv-md' });
  const before = reply.textContent ?? "";
  const problems = new Set<string>();
  const inspect = () => {
    const current = ctx.document.querySelector('[data-refresh-row="reply"] .cv-md');
    if (!history.isConnected || history.textContent !== HISTORY) problems.add("Earlier answer changed or remounted");
    if (current !== reply) problems.add("Refreshed reply remounted");
    if (!(current?.textContent ?? "").includes(before)) problems.add("Previously visible text disappeared");
    if (historical && current?.querySelector(".cv-fresh, .cv-enter")) problems.add("Historical text re-entered");
  };
  const Observer = ctx.document.defaultView!.MutationObserver;
  const observer = new Observer(inspect);
  observer.observe(ctx.find({ selector: "[data-refresh-fixture]" }), {
    subtree: true,
    childList: true,
    characterData: true,
    attributes: true,
  });
  try {
    await ctx.click({ role: "button", name: "Advance snapshot" });
    await ctx.waitFor(() => reply.textContent === rendered(expected));
    inspect();
    if (problems.size) throw new Error([...problems].join("; "));
  } finally {
    observer.disconnect();
  }
}

export default componentEntry<{ variant: Variant }>({
  id: "agent-pane.revealed-markdown-refresh",
  title: "Assistant text stays visible across refreshes",
  area: "Agent pane",
  pane: true,
  height: 320,
  widths: { narrow: 360, normal: 640 },
  anchors: [{ selector: '[data-refresh-row="history"]' }],
  covers: [
    "agent-session/acpmux/conversation/RevealedMarkdown.tsx",
    "agent-session/acpmux/conversation/revealedMarkdownModel.ts",
  ],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => RefreshFixture,
  variants: {
    "historical-refresh": {
      props: { variant: "historical-refresh" },
      note: "A settled suffix is replaced by the complete historical reply in place, without a new reveal.",
      play: (ctx) => advance(ctx, true, COMPLETE),
    },
    "truncated-reconnect": {
      props: { variant: "truncated-reconnect" },
      note: "A reconnect sends a shorter prefix, then the complete body; both updates keep the full reply visible.",
      play: async (ctx) => {
        await advance(ctx, true, COMPLETE);
        await advance(ctx, true, COMPLETE);
      },
    },
    "live-arrival": {
      props: { variant: "live-arrival" },
      note: "A new reply streams and settles while existing prose stays mounted and unchanged.",
      play: async (ctx) => {
        await advance(ctx, false, LIVE);
        await advance(ctx, false, LIVE);
        await ctx.waitFor(() => !ctx.document.querySelector(".cv-fresh"));
      },
    },
  },
});
