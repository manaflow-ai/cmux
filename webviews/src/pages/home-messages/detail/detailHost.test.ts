import { describe, expect, it } from "bun:test";
import { chatAppearance, parseAppearance, parseDictationUpdate, parseFirstRun, parseHeaderPanels } from "./detailHost";

describe("detail host parsers", () => {
  it("reads the appearance and lays a chat's colours over the defaults, field by field", () => {
    const appearance = parseAppearance({
      look: "outline",
      chiefLook: "theme",
      defaults: { sent: "#112233", receivedText: "#000000" },
      colors: { c1: { sent: "#abcdef", received: "red" }, c2: "junk" },
    });
    expect(chatAppearance(appearance, { id: "c1", kind: "direct" })).toEqual({
      look: "outline",
      colors: { sent: "#abcdef", receivedText: "#000000" },
    });
    expect(chatAppearance(appearance, { id: "c2", kind: "chief" })).toEqual({
      look: "theme",
      colors: { sent: "#112233", receivedText: "#000000" },
    });
  });

  it("defaults to iMessage, and a missing Chief look to the look", () => {
    expect(parseAppearance(undefined).look).toBe("imessage");
    const theme = parseAppearance({ look: "theme", chiefLook: "neon" });
    expect(theme.chiefLook).toBe("theme");
  });

  it("reads header panels, dropping entries without an id", () => {
    expect(
      parseHeaderPanels({
        enabled: true,
        panels: [{ id: "memory", isOn: true, shortcut: "⌥⌘M" }, { id: "rightSidebar" }, { isOn: true }],
      }),
    ).toEqual({
      enabled: true,
      panels: [
        { id: "memory", isOn: true, shortcut: "⌥⌘M" },
        { id: "rightSidebar", isOn: false },
      ],
    });
    expect(parseHeaderPanels(null)).toEqual({ enabled: false, panels: [] });
  });

  it("takes only dictation updates with a known state and text", () => {
    expect(parseDictationUpdate({ state: "listening", text: "hi", level: 3 })).toMatchObject({
      state: "listening",
      text: "hi",
      level: 1,
      cancelled: false,
    });
    expect(parseDictationUpdate({ state: "shouting", text: "" })).toBeUndefined();
    expect(parseDictationUpdate({ state: "idle" })).toBeUndefined();
  });

  it("reads the first run's host facts", () => {
    const facts = parseFirstRun({
      introKind: "welcome",
      memoryOffer: "Bring your memory",
      petShown: true,
      shortcuts: { terminal: "⌘T", agent: 4 },
      agents: [
        { id: "t1", title: "Build", icon: "terminal", status: "working" },
        { id: "t2", status: "sleeping" },
      ],
      switchKeys: { tabByNumber: "⌘1…9", desktopConflict: true },
      starters: { workspaces: ["cmux", 3] },
    });
    expect(facts).toEqual({
      introKind: "welcome",
      memoryOffer: "Bring your memory",
      petShown: true,
      shortcuts: { terminal: "⌘T" },
      agents: [{ id: "t1", title: "Build", icon: "terminal", status: "working" }],
      switchKeys: { tabByNumber: "⌘1…9", desktopConflict: true },
      starters: { workspaces: ["cmux"] },
    });
    expect(parseFirstRun("x")).toEqual({ shortcuts: {}, agents: [], starters: {} });
  });
});
