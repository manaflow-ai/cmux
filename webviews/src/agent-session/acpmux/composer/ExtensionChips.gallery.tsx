// l10n-allow-file: gallery fixtures for manifest-supplied chip labels and texts.
import { useMemo, useState } from "react";
import { MockAppPanelsClient } from "../../../apps/scene/panelsMock";
import { componentEntry } from "../../../gallery/format";
import { ExtensionChips } from "./ExtensionChips";

type Props = { chips: unknown[] };

const TEAM = { app: "samples/team-flow", extension: "Team flow" };

function ChipsExample({ chips }: Props) {
  const client = useMemo(() => {
    const mock = new MockAppPanelsClient();
    mock.composerChips = chips;
    return mock;
  }, [chips]);
  const [draft, setDraft] = useState("");
  return (
    <div className="acpmux-composer">
      <ExtensionChips client={client} onPick={(chip) => setDraft((text) => `${text}${chip.insert} `)} />
      <output>{draft}</output>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.composer-extension-chips",
  title: "Composer extension chips",
  area: "Agent pane",
  pane: true,
  height: 100,
  covers: ["agent-session/acpmux/composer/ExtensionChips.tsx"],
  load: async () => ChipsExample,
  styles: () => Promise.all([import("../styles.css"), import("../composerLocation.css")]),
  variants: {
    none: { props: { chips: [] } },
    one: {
      props: {
        chips: [
          {
            ...TEAM,
            id: "tests",
            label: "Failing tests",
            detail: "The CI run's failures",
            insert: "Fix the failing tests in CI.",
          },
        ],
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Failing tests" });
        await ctx.waitFor(() => ctx.document.querySelector("output")?.textContent === "Fix the failing tests in CI. ");
      },
    },
    several: {
      props: {
        chips: [
          { ...TEAM, id: "tests", label: "Failing tests", insert: "Fix the failing tests in CI." },
          { ...TEAM, id: "review", label: "Review notes", insert: "Address the review notes on this PR." },
          {
            app: "samples/standup",
            extension: "Standup",
            id: "today",
            label: "Today's plan",
            insert: "Plan today's work.",
          },
          {
            app: "samples/standup",
            extension: "Standup",
            id: "blockers",
            label: "Blockers",
            insert: "List what blocks me.",
          },
        ],
      },
    },
    "long-labels": {
      props: {
        chips: Array.from({ length: 12 }, (_, index) => ({
          ...TEAM,
          id: `chip-${index}`,
          label: `Context from the team's runbook ${index + 1}`,
          insert: `Runbook step ${index + 1}`,
        })),
      },
    },
  },
});
