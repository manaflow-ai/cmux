import { z } from "zod";

/**
 * Spec Data Model
 *
 * The spec is a derived view of Claude Code's conversation.
 * It's extracted from the output stream, not maintained as a file.
 */

export const DecisionSchema = z.object({
  id: z.string(),
  topic: z.string(),
  choice: z.string(),
  rationale: z.string(),
  timestamp: z.date(),
  approved: z.boolean().default(false),
});
export type Decision = z.infer<typeof DecisionSchema>;

export const QuestionSchema = z.object({
  id: z.string(),
  question: z.string(),
  context: z.string().optional(),
  options: z.array(z.string()).optional(),
  claudeSuggestion: z.string().optional(),
  status: z.enum(["open", "answered", "skipped"]).default("open"),
  answer: z.string().optional(),
  timestamp: z.date(),
});
export type Question = z.infer<typeof QuestionSchema>;

export const AssumptionSchema = z.object({
  id: z.string(),
  text: z.string(),
  flagged: z.boolean().default(false),
  correction: z.string().optional(),
  timestamp: z.date(),
});
export type Assumption = z.infer<typeof AssumptionSchema>;

export const SessionSpecSchema = z.object({
  sessionId: z.string(),
  taskRunId: z.string().optional(),

  // Extracted from Claude's messages
  decisions: z.array(DecisionSchema).default([]),
  questions: z.array(QuestionSchema).default([]),
  assumptions: z.array(AssumptionSchema).default([]),

  // Claude's current state
  currentFocus: z.string().optional(),
  blockedOn: z.string().optional(), // question ID if blocked

  // Metadata
  lastUpdated: z.date(),
  outputBuffer: z.string().default(""), // Buffer for partial output
});
export type SessionSpec = z.infer<typeof SessionSpecSchema>;

/**
 * Create an empty spec for a new session
 */
export function createEmptySpec(sessionId: string, taskRunId?: string): SessionSpec {
  return {
    sessionId,
    taskRunId,
    decisions: [],
    questions: [],
    assumptions: [],
    currentFocus: undefined,
    blockedOn: undefined,
    lastUpdated: new Date(),
    outputBuffer: "",
  };
}

/**
 * Check if the spec has any open questions
 */
export function hasOpenQuestions(spec: SessionSpec): boolean {
  return spec.questions.some((q) => q.status === "open");
}

/**
 * Get all open questions
 */
export function getOpenQuestions(spec: SessionSpec): Question[] {
  return spec.questions.filter((q) => q.status === "open");
}

/**
 * Check if the spec is blocked (has open question marked as blocking)
 */
export function isBlocked(spec: SessionSpec): boolean {
  return spec.blockedOn !== undefined;
}

/**
 * Answer a question in the spec
 */
export function answerQuestion(
  spec: SessionSpec,
  questionId: string,
  answer: string
): SessionSpec {
  return {
    ...spec,
    questions: spec.questions.map((q) =>
      q.id === questionId ? { ...q, status: "answered" as const, answer } : q
    ),
    blockedOn: spec.blockedOn === questionId ? undefined : spec.blockedOn,
    lastUpdated: new Date(),
  };
}

/**
 * Skip a question in the spec
 */
export function skipQuestion(spec: SessionSpec, questionId: string): SessionSpec {
  return {
    ...spec,
    questions: spec.questions.map((q) =>
      q.id === questionId ? { ...q, status: "skipped" as const } : q
    ),
    blockedOn: spec.blockedOn === questionId ? undefined : spec.blockedOn,
    lastUpdated: new Date(),
  };
}

/**
 * Flag an assumption as incorrect
 */
export function flagAssumption(
  spec: SessionSpec,
  assumptionId: string,
  correction: string
): SessionSpec {
  return {
    ...spec,
    assumptions: spec.assumptions.map((a) =>
      a.id === assumptionId ? { ...a, flagged: true, correction } : a
    ),
    lastUpdated: new Date(),
  };
}

/**
 * Approve a decision
 */
export function approveDecision(spec: SessionSpec, decisionId: string): SessionSpec {
  return {
    ...spec,
    decisions: spec.decisions.map((d) =>
      d.id === decisionId ? { ...d, approved: true } : d
    ),
    lastUpdated: new Date(),
  };
}
