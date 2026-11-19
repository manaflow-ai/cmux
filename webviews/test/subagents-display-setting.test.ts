import { afterEach, describe, expect, test } from "bun:test";
import { setChatDisplay, subagentsDisplay, SUBAGENTS_DISPLAY_KEY } from "../src/agent-session/acpmux/chatDisplay";
import {
  configureSubagentTray,
  subagentTrayShown,
  subscribeSubagentTray,
} from "../src/agent-session/acpmux/subagents/runningTray";

// Settings > Agent Chat > Subagents (`agentPane.display.subagents`; Leo: "Claude Code (and the
// Claude desktop app's Code tab) shows subagents and sub-sessions nested under the parent chat."):
// `tray`, the default, is today's running tray; `transcript` draws subagents as cards in the
// transcript, so the pane runs as with the Debug tunable off. The tunable off still wins.
afterEach(() => {
  setChatDisplay({});
  configureSubagentTray(undefined);
});

describe("agentPane.display.subagents", () => {
  test("the key is the schema's", () => {
    expect(SUBAGENTS_DISPLAY_KEY).toBe("agentPane.display.subagents");
  });

  test("unset, or set to tray or an unknown value, keeps the tray", () => {
    setChatDisplay({});
    expect(subagentsDisplay()).toBe("tray");
    expect(subagentTrayShown()).toBe(true);
    setChatDisplay({ [SUBAGENTS_DISPLAY_KEY]: "tray" });
    expect(subagentTrayShown()).toBe(true);
    setChatDisplay({ [SUBAGENTS_DISPLAY_KEY]: "inline" });
    expect(subagentsDisplay()).toBe("tray");
    expect(subagentTrayShown()).toBe(true);
  });

  test("transcript turns the tray off", () => {
    setChatDisplay({ [SUBAGENTS_DISPLAY_KEY]: "transcript" });
    expect(subagentsDisplay()).toBe("transcript");
    expect(subagentTrayShown()).toBe(false);
  });

  test("the Debug tunable off still wins over tray", () => {
    configureSubagentTray(false);
    setChatDisplay({ [SUBAGENTS_DISPLAY_KEY]: "tray" });
    expect(subagentTrayShown()).toBe(false);
    setChatDisplay({ [SUBAGENTS_DISPLAY_KEY]: "transcript" });
    expect(subagentTrayShown()).toBe(false);
  });

  test("a settings save notifies subscribers, so an open chat swaps live", () => {
    const seen: boolean[] = [];
    const off = subscribeSubagentTray(() => seen.push(subagentTrayShown()));
    setChatDisplay({ [SUBAGENTS_DISPLAY_KEY]: "transcript" });
    setChatDisplay({});
    configureSubagentTray(false);
    off();
    setChatDisplay({ [SUBAGENTS_DISPLAY_KEY]: "transcript" });
    expect(seen).toEqual([false, true, false]);
  });
});
