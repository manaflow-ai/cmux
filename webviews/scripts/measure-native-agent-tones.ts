// Same harness on base and head: shared identities reaching native Session Info and pane tabs.
import { translate } from "../src/agent-session/acpmux/i18n";
import { NativeInfoActions } from "../src/agent-session/acpmux/session-info/native/model";
import { subagentsSection } from "../src/agent-session/acpmux/session-info/native/subagents";
import { agentTone } from "../src/agent-session/acpmux/subagents/agentTones";
import { openSubagentPane } from "../src/agent-session/acpmux/subagents/subagentPanes";

const ids = Array.from({ length: 32 }, (_, index) => `agent-${index}`);
const section = subagentsSection(
  {
    open: true,
    showAll: true,
    agents: ids.map((id) => ({ id, name: id, parent: null, state: "running" as const, startedAt: 0 })),
    waiting: new Set(),
    sessions: [],
    now: 1_000,
  },
  new NativeInfoActions(),
  (key, values) => translate(key, values, "en"),
)!;
const rows = new Set(
  section.rows.filter((row) => row.identityTone === agentTone(row.id.slice(6))).map((row) => row.identityTone),
);
const tabs = new Set<number>();
for (const id of ids) {
  await openSubagentPane(
    async (_method, params) => {
      if (params.tone === agentTone(id)) tabs.add(params.tone as number);
      return { opened: true };
    },
    id,
    false,
    undefined,
    agentTone(id),
  );
}
console.log(JSON.stringify({ nativeRowTones: rows.size, nativeTabTones: tabs.size, agents: ids.length }));
