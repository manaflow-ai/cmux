import { expect, test } from "bun:test";
import { renderToString } from "react-dom/server";
import { setChatDisplay, SUBAGENT_OF_KEY, useSubagentOf } from "../chatDisplay";

// Subagent Of in Header (agentPane.display.subagentOf): opt-in, so a subagent's own pane names only
// the subagent unless the person turns it on.
function Probe() {
  return <i>{useSubagentOf() ? "on" : "off"}</i>;
}

test("the key is off by default and on only for a real true", () => {
  expect(SUBAGENT_OF_KEY).toBe("agentPane.display.subagentOf");
  setChatDisplay({});
  expect(renderToString(<Probe />)).toBe("<i>off</i>");
  setChatDisplay({ [SUBAGENT_OF_KEY]: "on" });
  expect(renderToString(<Probe />)).toBe("<i>off</i>");
  setChatDisplay({ [SUBAGENT_OF_KEY]: true });
  expect(renderToString(<Probe />)).toBe("<i>on</i>");
  setChatDisplay({});
  expect(renderToString(<Probe />)).toBe("<i>off</i>");
});
