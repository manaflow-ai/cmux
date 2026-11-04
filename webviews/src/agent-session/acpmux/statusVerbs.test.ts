import { afterEach, describe, expect, test } from "bun:test";
import {
  DEFAULT_STATUS_VERBS,
  STATUS_VERB_INTERVAL_MS,
  configureStatusVerbs,
  resolveStatusVerbConfig,
  statusVerbAt,
} from "./statusVerbs";

afterEach(() => configureStatusVerbs(undefined));

describe("status verbs", () => {
  test("rotates the default list at a stable interval", () => {
    expect(statusVerbAt(0)).toBe(DEFAULT_STATUS_VERBS[0]);
    expect(statusVerbAt(STATUS_VERB_INTERVAL_MS - 1)).toBe(DEFAULT_STATUS_VERBS[0]);
    expect(statusVerbAt(STATUS_VERB_INTERVAL_MS)).toBe(DEFAULT_STATUS_VERBS[1]);
    expect(statusVerbAt(-1)).toBe(DEFAULT_STATUS_VERBS[0]);
  });

  test("supports thinking only mode", () => {
    const config = resolveStatusVerbConfig({ "agentPane.display.statusVerbs.mode": "thinking" });
    expect(config).toEqual({ mode: "thinking", verbs: ["Thinking"] });
    expect(statusVerbAt(STATUS_VERB_INTERVAL_MS * 20, config)).toBe("Thinking");
  });

  test("trims, de-duplicates and rotates a custom comma list", () => {
    const config = resolveStatusVerbConfig({
      "agentPane.display.statusVerbs.mode": "custom",
      "agentPane.display.statusVerbs.custom": "  Reading, Planning, Reading,  Testing ",
    });
    expect(config).toEqual({ mode: "custom", verbs: ["Reading", "Planning", "Testing"] });
    expect(statusVerbAt(0, config)).toBe("Reading");
    expect(statusVerbAt(STATUS_VERB_INTERVAL_MS, config)).toBe("Planning");
    expect(statusVerbAt(STATUS_VERB_INTERVAL_MS * 2, config)).toBe("Testing");
  });

  test("malformed custom values fall back to Thinking only", () => {
    expect(resolveStatusVerbConfig({ "agentPane.display.statusVerbs.mode": "custom" })).toEqual({
      mode: "thinking",
      verbs: ["Thinking"],
    });
    expect(resolveStatusVerbConfig({ "agentPane.display.statusVerbs.mode": "unknown" })).toEqual({
      mode: "rotate",
      verbs: DEFAULT_STATUS_VERBS,
    });
  });

  test("a one-word custom list retains the chosen word", () => {
    const config = resolveStatusVerbConfig({
      "agentPane.display.statusVerbs.mode": "custom",
      "agentPane.display.statusVerbs.custom": "Imagining",
    });
    expect(statusVerbAt(0, config)).toBe("Imagining");
    expect(statusVerbAt(STATUS_VERB_INTERVAL_MS * 10, config)).toBe("Imagining");
  });
});

