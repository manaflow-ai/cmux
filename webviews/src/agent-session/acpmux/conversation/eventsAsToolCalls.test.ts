// The design "Events that are tool calls" (cmuxterm-hq docs/design/events-that-are-tool-calls.md),
// plan item "Add `subagent_resume` and `announcement` to the known kinds", behind
// `experiments.eventsAsToolCalls` (off by default): off reads as before, on reads both kinds by origin.
import { afterEach, expect, test } from "bun:test";
import { setExperimentSwitches } from "../../../experiments/switches";
import { EVENTS_AS_TOOL_CALLS_SWITCH } from "./eventsAsToolCalls.experiment";
import { incomingPrompt } from "./incomingMessage";

afterEach(() => setExperimentSwitches({}));

const on = () => setExperimentSwitches({ [EVENTS_AS_TOOL_CALLS_SWITCH]: true });

// hub/forum.rs `push`: an urgent rule's prompt, provenance with no sender of its own.
const rule = "Rule [ship-small] from leo (a person), an instruction: follow it\n> Keep PRs under 400 lines.";
const announcement = {
  _meta: { provenance: { kind: "announcement", postId: "p1", key: "ship-small", author: { person: {} }, to: "s1" } },
};

test("off by default: an urgent forum rule reads as it did (the person's prompt)", () => {
  expect(incomingPrompt(rule, announcement)).toBeUndefined();
});

test("on: an urgent forum rule draws as acpmux's line, never as the person's prompt", () => {
  on();
  expect(incomingPrompt(rule, announcement)).toEqual({
    kind: "message",
    message: { name: "acpmux", text: rule, raw: rule },
  });
});

// hub/subagent_resume.rs: the row's Resume, provenance `{kind, subagentId, agentId?, name?, from?}`.
const resume = "Start the subagent again with the Agent tool … [acpmux-resume:toolu_1]";
const resumeFromAgent = {
  _meta: { provenance: { kind: "subagent_resume", subagentId: "toolu_1", from: "acp:abc", fromName: "coord" } },
};

test("off by default: a subagent Resume that names a sender reads as that agent's message", () => {
  const prompt = incomingPrompt(resume, resumeFromAgent);
  expect(prompt?.kind).toBe("message");
});

test("on: a subagent Resume is acpmux's own prompt, never an agent's message under its name", () => {
  on();
  expect(incomingPrompt(resume, resumeFromAgent)).toBeUndefined();
});

test("on: kinds the design does not name keep today's reading", () => {
  on();
  const text = "3 messages waited: 1 block, 2 FYIs";
  expect(incomingPrompt(text, { _meta: { provenance: { kind: "inbox_digest" } } })).toEqual({
    kind: "message",
    message: { name: "acpmux", text, raw: text },
  });
  const unknown = { _meta: { provenance: { kind: "brand_new_kind", from: "acp:abc", fromName: "coord" } } };
  expect(incomingPrompt("hi", unknown)?.kind).toBe("message");
});
