import { afterEach, describe, expect, test } from "bun:test";
import {
  STATUS_VERB_INTERVAL_MS,
  configureStatusVerbs,
  resolveStatusVerbConfig,
  statusVerbAt,
  statusVerbLabels,
} from "./statusVerbs";
import { THINKING_VERBS } from "./conversation/thinkingVerbs";

import { translatorFor } from "./i18n";

afterEach(() => configureStatusVerbs(undefined));

describe("status verbs", () => {
  test("keeps the default on bare Thinking", () => {
    expect(resolveStatusVerbConfig(undefined)).toEqual({ mode: "thinking", verbs: ["Thinking"] });
    expect(statusVerbAt(STATUS_VERB_INTERVAL_MS * 20)).toBe("Thinking");
  });

  test("recognizes the opt-in per-turn mode", () => {
    const config = resolveStatusVerbConfig({ "agentPane.display.statusVerbs.mode": "rotate" });
    expect(config).toEqual({ mode: "rotate", verbs: [] });
    expect(statusVerbAt(STATUS_VERB_INTERVAL_MS * 20, config)).toBe("Thinking");
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
      mode: "thinking",
      verbs: ["Thinking"],
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

test("incomplete locales keep their translated Thinking for the entire rotation", () => {
  const t = translatorFor("ja");
  const config = resolveStatusVerbConfig(undefined);
  expect(statusVerbLabels(t, config)).toEqual([t("thinking")]);
  const custom = resolveStatusVerbConfig({
    "agentPane.display.statusVerbs.mode": "custom",
    "agentPane.display.statusVerbs.custom": "Planning, Testing",
  });
  expect(statusVerbLabels(t, custom)).toEqual(["Planning", "Testing"]);
});

test("the built-in list stays behind the explicit Rotate context", () => {
  const t = translatorFor("ja");
  const words = statusVerbLabels(t, resolveStatusVerbConfig({ "agentPane.display.statusVerbs.mode": "rotate" }));
  expect(words).toEqual([t("thinking")]);
  expect(THINKING_VERBS).toHaveLength(61);
  expect(
    statusVerbLabels(
      t,
      resolveStatusVerbConfig({
        "agentPane.display.statusVerbs.mode": "thinking",
      }),
    ),
  ).toEqual([t("thinking")]);
});
