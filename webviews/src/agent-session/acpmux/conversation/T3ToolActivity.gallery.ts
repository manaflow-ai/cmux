// l10n-allow-file: gallery scenarios, never shipped UI copy.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";
import { toolActivityPresentation } from "./toolActivityPresentation.experiment";

const cases = {
  completed: "Open Worked for to recover all earlier messages and tools, unchanged.",
  running: "Open the live activity row to inspect the tools in progress.",
  stopped: "The stopped turn stays expanded so its partial response can be read.",
  failed: "The failure and the turn's full activity stay visible.",
  permission: "The pending edit and approval stay outside collapsed activity.",
  steered: "The personal steer keeps its place between the two stretches of work.",
  "long-answer-short-ending":
    "The substantial earlier answer is under Worked for. The last reply, Done, stays visible, exactly as T3 selects it.",
  "background-turn": "A new activity group after a completed turn has its own live disclosure.",
} as const;
type Scenario = keyof typeof cases;
const families = ["claude", "codex", "gemini", "muse"] as const;
const models = { claude: "claude-opus-5-5", codex: "gpt-6-astra", gemini: "gemini-3-pro", muse: "muse-code" };
const command = (title: string, status = "completed") =>
  tool(title, "execute", status, {
    command: `echo '${title}'`,
    output: status === "completed" ? "3 pass\n0 fail\n" : undefined,
  });

function snapshot(family: (typeof families)[number], scenario: Scenario) {
  const rows: AcpmuxRow[] = [
    user("Check the retry helper and its tests.", 6),
    activity(
      [
        tool("Read retry helper", "read", "completed", {
          output: "export const retryLimit = 3;",
          locations: [{ path: "src/retry.ts" }],
        }),
        command("Run focused tests"),
      ],
      5,
    ),
    assistant(
      scenario === "long-answer-short-ending"
        ? "The retry helper handles server errors correctly.\n\n- Keep retries for 408 and 429.\n- Fail other client errors immediately.\n\nThis entire answer must remain available when the turn is expanded."
        : "The tests passed.",
      4,
    ),
  ];
  if (scenario === "steered") rows.push(user("Also check the callers.", 3.5, { steer: "landed" }));
  if (scenario === "background-turn") rows.push(summary(3.5, { status: "completed" }));
  rows.push(
    activity(
      [
        command("Inspect the changes"),
        command(
          "Check all callers",
          scenario === "running" || scenario === "background-turn" ? "in_progress" : "completed",
        ),
      ],
      2,
    ),
  );
  if (scenario === "permission") {
    rows.push(
      activity(
        [
          tool("Update retry limit", "edit", "pending", {
            diffs: [{ path: "src/retry.ts", oldText: "const retryLimit = 3;", newText: "const retryLimit = 2;" }],
          }),
        ],
        1,
      ),
    );
    rows.push(
      row("permission", 0.5, {
        permission: {
          permissionId: "t3-edit",
          title: "Allow editing src/retry.ts?",
          pending: true,
          options: [
            { id: "allow", name: "Allow once", allow: true },
            { id: "deny", name: "Deny", allow: false },
          ],
        },
      }),
    );
  } else if (scenario !== "running" && scenario !== "background-turn") {
    rows.push(
      assistant(scenario === "long-answer-short-ending" ? "Done." : "The helper and its callers are checked.", 1),
    );
    rows.push(
      summary(0.5, {
        status: scenario === "stopped" ? "cancelled" : scenario === "failed" ? "failed" : "completed",
        toolCount: 4,
        durationMs: 48_000,
        ...(scenario === "failed" && { error: "The model connection closed before the turn finished." }),
      }),
    );
  }
  const base = chat(rows, {
    title: `Tool activity · ${family} · ${scenario}`,
    harness: family,
    model: models[family],
    isWorking: scenario === "running" || scenario === "background-turn" || scenario === "permission",
  });
  return { ...base, summary: { ...base.summary!, family } };
}
const variants: Record<string, AgentPaneVariant> = {};
for (const family of families)
  for (const scenario of Object.keys(cases) as Scenario[]) {
    variants[`${family}-${scenario}`] = {
      snapshot: snapshot(family, scenario),
      note: `${family}: ${cases[scenario]} Mock conversations only; buttons never run real commands. Compare Current and T3 Code, then try light/dark and narrow/wide.`,
    };
  }

export default agentPaneEntry({
  id: "agent-pane.t3-tool-activity",
  title: "T3 Code activity: interactive cases",
  area: "Agent pane",
  height: 720,
  widths: { narrow: 520, normal: 760, wide: 1000 },
  covers: [
    "agent-session/acpmux/conversation/TurnRows.tsx#WorkedFor",
    "agent-session/acpmux/conversation/Thinking.tsx",
    "agent-session/acpmux/conversation/TurnRows.tsx#ToolRows",
  ],
  experiment: {
    definition: toolActivityPresentation,
    script: [
      {
        name: "Open activity",
        run: async (ctx) => {
          await ctx.waitFor(() => ctx.document.querySelector(".cv-worked, .cv-tool"), { capMs: 10000 });
          ctx.document
            .querySelector<HTMLButtonElement>(
              ".cv-live-disclosure__toggle, button.cv-worked.is-toggle, button.cv-tool.is-toggle",
            )
            ?.click();
        },
      },
      {
        name: "Close activity",
        run: async (ctx) => {
          ctx.document
            .querySelector<HTMLButtonElement>(
              ".cv-live-disclosure__toggle, button.cv-worked.is-toggle, button.cv-tool.is-toggle",
            )
            ?.click();
        },
      },
    ],
  },
  variants,
});
