// l10n-allow-file: gallery fixtures (a sample chat and its suggestion) and comparison notes, not shipped UI.
// One composer whatever machine the agent runs on (Leo, 2026-11-07: "the right side doesn't have the,
// like, really prominent glass outline in the composer. But the left one does. And it's like, wait,
// why is there— why can this styling be different? ... why does the right one have the prompt
// suggestion and the left one doesn't?"). The same chat on this Mac, on another machine through this
// Mac's acpmux (a peer), over the app's remote wire to that machine's acpmux, and on Cloud: each pair
// is the same state, so the cells side by side should match. What may differ is the chat's own
// state: the prompt's focus (the focused card's hairline lifts a step, composerStates.css) and
// whether the agent sent a suggested next prompt (snapshot `promptSuggestion`). The rim and glass
// read nothing about the machine; composer-any-host.test.ts reads the computed outline back.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { assistant, chat, session, summary, user } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";
import { PROMPT_SUGGESTIONS_OPTION } from "./mockFixture";

const SESSION = "any-host-chat";
const SUGGESTION = "Add a test for the retry backoff";
const MACHINE = "build-box";

/** Where the chat runs: this Mac, a peer of this Mac's acpmux, that machine's acpmux over the app's remote wire, or Cloud. */
export const HOSTS = ["this-mac", "peer", "remote", "cloud"] as const;
export type Host = (typeof HOSTS)[number];

const HOST_NOTES: Record<Host, string> = {
  "this-mac": "On this Mac",
  peer: "On another machine, through this Mac's acpmux",
  remote: "On another machine, over the app's remote wire to its acpmux",
  cloud: "On a Cloud machine",
};

/** The same finished Claude chat, run on `host`; with `suggested`, the agent sent a next prompt. */
export function onHost(host: Host, suggested: boolean): AcpmuxSnapshot {
  const remoteHost = host === "cloud" ? "cloud-1" : MACHINE;
  const base = chat(
    [
      user("Why do uploads fail on the fleet?", 12),
      assistant("The uploader gives up on the first 503 from the artifact store.", 11),
      summary(11, { status: "completed" }),
      user("Retry 5xx with backoff", 6),
      assistant("Done: the uploader retries 5xx with backoff, up to five tries.", 5),
      summary(5, { status: "completed" }),
    ],
    {
      sessionId: SESSION,
      sessions: [
        session({
          sessionId: SESSION,
          title: "Add retries to the fetch helper",
          ...(host === "this-mac" ? {} : { host: remoteHost }),
          ...(host === "cloud" ? { hostKind: "cloud" as const } : {}),
        }),
      ],
      ...(host === "remote" || host === "cloud" ? { origin: "remote" as const } : {}),
      ...(host === "peer" ? { origin: "peer" as const } : {}),
      ...(host === "cloud" ? { ownerCloud: true } : {}),
    },
  );
  const where =
    host === "this-mac"
      ? {}
      : host === "cloud"
        ? { host: remoteHost, peer: remoteHost, hostKind: "cloud" as const }
        : host === "peer"
          ? { host: remoteHost, peer: remoteHost }
          : { machine: remoteHost };
  return {
    ...base,
    summary: {
      ...base.summary!,
      ...where,
      configOptions: [...(base.summary?.configOptions ?? []), PROMPT_SUGGESTIONS_OPTION],
    },
    ...(suggested ? { promptSuggestion: { text: SUGGESTION, seq: 40 } } : {}),
  };
}

const PROMPT = ".acpmux-composer > .acpmux-composer-box [contenteditable='true']";
const BOX = ".acpmux-composer > .acpmux-composer-box";

/// A resting stage blurs the prompt the pane focuses on mount and waits until the card holds no
/// focus; a focused stage focuses it from the keyboard's side and waits for :has(:focus-visible), the
/// rule that lifts the rim. `data-composer-any-host` marks the stage as reached.
async function stage(ctx: PlayContext, focused: boolean) {
  await ctx.waitFor(() => ctx.document.querySelector(PROMPT));
  const box = ctx.document.querySelector<HTMLElement>(BOX)!;
  if (focused) {
    await ctx.focus({ selector: PROMPT });
    await ctx.waitFor(() => box.matches(":has(:focus-visible)"));
  } else {
    await ctx.waitFor(() => {
      if (box.matches(":focus-within")) (ctx.document.activeElement as HTMLElement | null)?.blur();
      return !box.matches(":focus-within");
    });
  }
  ctx.document.documentElement.dataset.composerAnyHost = focused ? "focused" : "rest";
}

const STATES = {
  rest: { focused: false, suggested: false, note: "At rest, no suggestion." },
  focused: { focused: true, suggested: false, note: "The prompt focused: the hairline lifts a step." },
  suggested: {
    focused: false,
    suggested: true,
    note: "The agent sent a suggested next prompt: the empty prompt shows it as ghost text.",
  },
} as const;
export type State = keyof typeof STATES;

const variants: Record<string, AgentPaneVariant> = Object.fromEntries(
  (Object.keys(STATES) as State[]).flatMap((state) =>
    HOSTS.map((host) => {
      const { focused, suggested, note } = STATES[state];
      return [
        `${host}-${state}`,
        {
          note: `${HOST_NOTES[host]}. ${note}`,
          snapshot: onHost(host, suggested),
          play: (ctx: PlayContext) => stage(ctx, focused),
        },
      ];
    }),
  ),
);

export default agentPaneEntry({
  id: "agent-pane.composer-any-host",
  title: "Composer on this Mac and on another machine",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 620, wide: 760 },
  covers: ["agent-session/acpmux/ComposerBox.tsx#ComposerBox", "agent-session/acpmux/Composer.tsx#Composer"],
  keywords: ["remote", "machine", "host", "rim", "glass", "outline", "suggestion"],
  variants,
});
