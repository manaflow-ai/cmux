import { expect, test } from "bun:test";
import { openAgentSetupPane, parseAgentSetup, savedPrompt } from "./agentSetup";

test("reads acpmux's agent setup answer", () => {
  expect(
    parseAgentSetup({
      harness: "claude",
      family: "claude",
      harnessPrompt: { source: "Claude Code", note: "Built in.", link: "https://example.com" },
      servers: [
        { name: "acpmux", instructions: "Use bg_start.", tools: [{ name: "bg_start", description: "Run it." }] },
        { name: "cmux-cua", instructions: null, tools: [] },
        { name: "", tools: [] },
      ],
      preset: { name: "p", hasSystemPrompt: true, systemPrompt: "Hi", takesSystemPrompt: true, editable: true },
    }),
  ).toEqual({
    harness: "claude",
    family: "claude",
    harnessPrompt: { source: "Claude Code", note: "Built in.", link: "https://example.com" },
    servers: [
      { name: "acpmux", instructions: "Use bg_start.", tools: [{ name: "bg_start", description: "Run it." }] },
      { name: "cmux-cua", tools: [] },
    ],
    preset: { name: "p", hasSystemPrompt: true, systemPrompt: "Hi", takesSystemPrompt: true, editable: true },
  });
});

test("a chat without a preset, and a reply that is not one", () => {
  const setup = parseAgentSetup({
    harness: "codex",
    family: "codex",
    harnessPrompt: { source: "Codex", note: "", link: null },
    servers: [],
    preset: null,
  });
  expect(setup?.preset).toBeUndefined();
  expect(setup?.harnessPrompt.link).toBeUndefined();
  expect(parseAgentSetup(null)).toBeUndefined();
  expect(parseAgentSetup({ servers: [] })).toBeUndefined();
});

test("Save sends null for an empty prompt", () => {
  expect(savedPrompt("  \n")).toBeNull();
  expect(savedPrompt("Be brief.")).toBe("Be brief.");
});

test("a host that opens no tab answers false", async () => {
  expect(await openAgentSetupPane(async () => ({ opened: true }), "s")).toBe(true);
  expect(await openAgentSetupPane(async () => ({}), "s")).toBe(false);
  expect(await openAgentSetupPane(() => Promise.reject(new Error("unknown method")), "s")).toBe(false);
});
