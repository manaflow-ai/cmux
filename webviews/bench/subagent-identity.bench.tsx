// Count visually distinct Claude identities with the same three stable ids, on base and head.
import { renderToStaticMarkup } from "react-dom/server";
import { AgentLine } from "../src/agent-session/acpmux/subagents/AgentLine";
import { agentTone } from "../src/agent-session/acpmux/subagents/agentTones";

const ids = ["reviewer", "explorer", "writer"];
const hues = ids.map((id) => {
  const html = renderToStaticMarkup(
    <AgentLine name={id} mark="claude" tone={agentTone(id)} state="Done" status="done" />,
  );
  return /data-agent-tone="(\d)" data-identity-look="tint"/.exec(html)?.[1] ?? "brand";
});
console.log(JSON.stringify({ agents: ids.length, distinctKnownHarnessHues: new Set(hues).size, hues }));
