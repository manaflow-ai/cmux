// l10n-allow-file: synthetic replay fixtures, not shipped UI.
// Leo, 2026-11-27: "idk what happened here the ui is so awkward i think cmux/acpmux doesn't have good enough error handling in this case or something? idk"
// Replay the daemon's raw failed diagnostics plus its recoverable capacityWait through the real
// fold. Eleven exhausted-account responses must remain one calm pause; a genuine error stays visible.
import { agentPaneEntry } from "../../../gallery/format";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { SubagentFold } from "./subagentFold";

const ERROR = "429 no non-exhausted claude accounts available; retry after 60s";
const TURN = "capacity-storm-turn";
const wait = {
  reason: "capacity" as const,
  since: GALLERY_NOW - 60_000,
  resumesAt: GALLERY_NOW + 180_000,
  error: ERROR,
};

export function capacityStormSnapshot(state: "paused" | "recovered" | "mixed") {
  const fold = new SubagentFold();
  fold.harness = "claude";
  fold.session = "gallery-session";
  let seq = 0;
  const feed = (sessionUpdate: string, subagents: Record<string, unknown>[], minutes: number) => {
    const update = { sessionUpdate };
    fold.reduce(
      {
        seq: ++seq,
        at: minutesAgo(minutes),
        msg: {
          method: "session/update",
          params: { update, _meta: { acpmux: { subagents } } },
        },
      },
      update,
    );
  };
  const ids = Array.from({ length: 11 }, (_, i) => `gallery-session/helper-${i + 1}`);
  ids.forEach((id, i) =>
    feed(
      "subagent_spawned",
      [
        {
          id,
          parent: null,
          name: `Review part ${i + 1}`,
          prompt: `Review part ${i + 1}`,
          kind: "general-purpose",
          state: "running",
          background: true,
        },
      ],
      27,
    ),
  );
  ids.forEach((id, i) => {
    const genuine = state === "mixed" && i === 10;
    feed(
      "subagent_state_update",
      [
        {
          id,
          parent: null,
          state: "failed",
          retryable: true,
          error: genuine ? "Repository access was permanently denied." : ERROR,
          capacityWait: genuine ? null : wait,
          retry: genuine
            ? null
            : {
                outcome: "scheduled",
                attempt: 1,
                of: 4,
                reason: "capacity",
                nextAt: wait.resumesAt,
              },
        },
      ],
      1,
    );
    if (state === "recovered") {
      feed(
        "subagent_state_update",
        [
          {
            id,
            parent: null,
            state: "running",
            capacityWait: null,
            retry: {
              outcome: "inflight",
              attempt: 1,
              of: 4,
              reason: "capacity",
            },
          },
        ],
        0.8,
      );
      feed(
        "subagent_state_update",
        [
          {
            id,
            parent: null,
            state: "completed",
            capacityWait: null,
            retry: null,
            retryInFlight: null,
            error: null,
          },
        ],
        0.5,
      );
    }
  });
  const recovered = state === "recovered";
  return chat(
    [
      user("Review the change in eleven parallel helpers.", 27.1, {
        turnId: TURN,
      }),
      assistant("The helpers are reviewing their assigned parts.", 27, {
        turnId: TURN,
      }),
      ...fold.takeRows(),
      ...(recovered
        ? [assistant("All eleven helpers resumed and completed their reviews.", 0.4, { turnId: TURN })]
        : []),
      summary(0.3, {
        turnId: TURN,
        status: recovered ? "completed" : "failed",
        durationMs: 1_583_000,
        ...(recovered ? {} : { error: ERROR }),
      }),
    ],
    {
      title: "Parallel review",
      ...(recovered ? {} : { capacityWait: { ...wait, turnId: TURN } }),
    },
  );
}

export default agentPaneEntry({
  id: "agent-pane.subagent-capacity-storm",
  title: "Eleven helpers waiting for capacity",
  area: "Agent pane",
  height: 580,
  covers: [
    "agent-session/acpmux/subagents/SubagentGroup.tsx",
    "agent-session/acpmux/subagents/subagentFold.ts",
    "agent-session/acpmux/conversation/TurnRows.tsx",
  ],
  variants: {
    paused: {
      note: "Eleven raw failed helper updates held for capacity, plus the parent waiting: one calm grouped indicator.",
      snapshot: capacityStormSnapshot("paused"),
    },
    recovered: {
      note: "All eleven helpers automatically resumed and completed: no stale paused or failed markers.",
      snapshot: capacityStormSnapshot("recovered"),
    },
    mixed: {
      note: "Ten helpers held for capacity and one genuinely failed: preserve the real error alongside the pause.",
      snapshot: capacityStormSnapshot("mixed"),
    },
  },
});
