import { expect, test } from "bun:test";
import { relevantModelSections } from "./relevantModels";

test("puts the active model's family first while keeping one newest model per family", () => {
  const models = [
    { id: "opus-5-5", name: "Opus 5.5", family: "Opus" },
    { id: "sonnet-5-5", name: "Sonnet 5.5", family: "Sonnet" },
    { id: "haiku-5-5", name: "Haiku 5.5", family: "Haiku" },
    { id: "opus-4-1", name: "Opus 4.1", family: "Opus" },
  ];
  const sections = relevantModelSections(models, undefined, "sonnet-5-5");
  expect(sections.shown.map((model) => model.id)).toEqual(["sonnet-5-5", "opus-5-5", "haiku-5-5"]);
  expect(sections.more.map((model) => model.id)).toEqual(["opus-4-1"]);
});

test("uses an offer's family when the active provider row is grouped", () => {
  const models = [
    {
      id: "claude-sonnet",
      name: "Sonnet 5.5",
      family: "Sonnet",
      offers: [{ id: "anthropic/claude-sonnet", family: "Sonnet" }],
    },
    { id: "claude-opus", name: "Opus 5.5", family: "Opus" },
  ];
  expect(relevantModelSections(models, undefined, "anthropic/claude-sonnet").shown[0]?.id).toBe("claude-sonnet");
});

test("matches a running concrete release to its alias row", () => {
  const models = [
    { id: "opus", name: "Opus 5.5", release: "claude-opus-5-5", family: "Opus" },
    { id: "sonnet", name: "Sonnet 5.5", release: "claude-sonnet-5-5", family: "Sonnet" },
  ];
  expect(relevantModelSections(models, undefined, "claude-opus-5-5").shown[0]?.id).toBe("opus");
});

test("normalizes inferred and explicit family metadata together", () => {
  const models = [
    { id: "claude-sonnet-4", name: "Sonnet 4" },
    { id: "claude-sonnet-5", name: "Sonnet 5", family: "Sonnet" },
    { id: "claude-opus-5", name: "Opus 5", family: "Opus" },
  ];
  const sections = relevantModelSections(models, undefined, "claude-sonnet-4");
  expect(sections.shown.map((model) => model.id)).toEqual(["claude-sonnet-5", "claude-opus-5"]);
  expect(sections.more.map((model) => model.id)).toEqual(["claude-sonnet-4"]);
});

test("infers the active family when reports omit family metadata", () => {
  const models = [
    { id: "opus-5-5", name: "Opus 5.5" },
    { id: "sonnet-5-5", name: "Sonnet 5.5" },
    { id: "opus-4-1", name: "Opus 4.1" },
  ];
  expect(relevantModelSections(models, undefined, "sonnet-5-5").shown.map((model) => model.id)).toEqual([
    "sonnet-5-5",
    "opus-5-5",
  ]);
});
