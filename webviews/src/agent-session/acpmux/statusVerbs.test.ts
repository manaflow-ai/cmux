import { afterEach, describe, expect, test } from "bun:test";
import {
  DEFAULT_STATUS_VERBS,
  STATUS_VERB_INTERVAL_MS,
  configureStatusVerbs,
  resolveStatusVerbConfig,
  statusVerbAt,
  statusVerbLabels,
} from "./statusVerbs";

import { translatorFor } from "./i18n";

afterEach(() => configureStatusVerbs(undefined));

describe("status verbs", () => {
  test("keeps the default on bare Thinking", () => {
    expect(resolveStatusVerbConfig(undefined)).toEqual({ mode: "thinking", verbs: ["Thinking"] });
    expect(statusVerbAt(STATUS_VERB_INTERVAL_MS * 20)).toBe("Thinking");
  });

  test("rotates the opt-in list at a stable interval", () => {
    const config = resolveStatusVerbConfig({ "agentPane.display.statusVerbs.mode": "rotate" });
    expect(statusVerbAt(0, config)).toBe(DEFAULT_STATUS_VERBS[0]);
    expect(statusVerbAt(STATUS_VERB_INTERVAL_MS - 1, config)).toBe(DEFAULT_STATUS_VERBS[0]);
    expect(statusVerbAt(STATUS_VERB_INTERVAL_MS, config)).toBe(DEFAULT_STATUS_VERBS[1]);
    expect(statusVerbAt(-1, config)).toBe(DEFAULT_STATUS_VERBS[0]);
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
  expect(statusVerbLabels(t, "ja", config, {})).toEqual([t("thinking")]);
  const partial = { thinking: "考え中", "turn.live.verb.exploring": "探索中" };
  expect(statusVerbLabels(t, "ja", config, partial)).toEqual([t("thinking")]);
  const custom = resolveStatusVerbConfig({
    "agentPane.display.statusVerbs.mode": "custom",
    "agentPane.display.statusVerbs.custom": "Planning, Testing",
  });
  expect(statusVerbLabels(t, "ja", custom, partial)).toEqual(["Planning", "Testing"]);
});

test("complete locales rotate translated labels and thinking-only stays localized", () => {
  const t = translatorFor("ja");
  const words = statusVerbLabels(t, "ja", resolveStatusVerbConfig({ "agentPane.display.statusVerbs.mode": "rotate" }));
  expect(words).toHaveLength(DEFAULT_STATUS_VERBS.length);
  expect(words[0]).toBe(t("thinking"));
  expect(words).not.toContain("Exploring");
  expect(
    statusVerbLabels(
      t,
      "ja",
      resolveStatusVerbConfig({
        "agentPane.display.statusVerbs.mode": "thinking",
      }),
    ),
  ).toEqual([t("thinking")]);
});
