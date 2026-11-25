import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { experimentArm } from "../../../experiments/experiment";
import { AgentLine } from "./AgentLine";
import { trayLatestLook } from "./trayLatest.experiment";

test("the running tray defaults to rendering latest activity inline", () => {
  const latestAt = experimentArm(trayLatestLook, { overrides: {}, stored: {} });
  expect(latestAt).toBe("inline");
  const latestPlacement = latestAt === "tooltip" ? undefined : latestAt;
  const html = renderToStaticMarkup(
    <AgentLine
      name="Review the tray"
      latest="Read SubagentTray.tsx"
      latestAt={latestPlacement}
      status="running"
      state="Running"
    />,
  );
  expect(html).toContain("acpmux-agent-line__latest-inline");
  expect(html).not.toContain('acpmux-agent-line__latest"');
});
