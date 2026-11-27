// l10n-allow-file: test commands, not shipped UI.
// The groups header's words (HeadSummary.tsx) change on the one text roll every live label shares
// (trayMotion.tsx `Tick`): "Explore update code" turned to "2 subagents" as a hard swap, the one
// header arm whose words never ticked (measured in the gallery's subagent-tray-motion, groups arm).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { translate } from "../i18n";
import { HeadSummary } from "./HeadSummary";
import { trayItems } from "./runningTray";
import { trayHeadGroups } from "./trayHeadKinds";
import type { Subagent } from "./subagentFold";

const agent = (id: string): Subagent => ({
  id,
  parent: null,
  name: `Agent ${id}`,
  task: `Agent ${id}`,
  kind: "Explore",
  state: "running",
  startedAt: 1_794_000_000_000,
});

test("each kind's words in the groups header sit in a text roll cell", () => {
  const items = trayItems([agent("a"), agent("b")], [], [], true);
  const parts = trayHeadGroups(translate, { items, finished: [], waiting: new Set() });
  const html = renderToStaticMarkup(
    <HeadSummary
      t={translate}
      parts={parts}
      separator="·"
      markSize={14}
      mark={() => null}
      nameOf={(item) => item.id}
    />,
  );
  // The kind-text cell is a Tick (TextRoll `acpmux-tick`), not a bare span.
  expect(html).toMatch(
    /<span class="[^"]*acpmux-tick[^"]*acpmux-running-tray__kind-text|<span class="[^"]*acpmux-running-tray__kind-text[^"]*acpmux-tick/,
  );
});
