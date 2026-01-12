import { randomUUID } from "node:crypto";
import type { SessionSpec, Decision, Question, Assumption } from "./spec.js";

/**
 * Extraction Layer
 *
 * Parses Claude Code output for structured markers:
 * - DECISION: [topic] -> [choice] because [reason]
 * - QUESTION: [question] OPTIONS: [opt1] | [opt2] LEANING: [suggestion]
 * - ASSUMING: [assumption]
 * - FOCUS: [what working on]
 *
 * Also supports natural language patterns that indicate decisions/questions.
 */

// Regex patterns for structured markers
const DECISION_PATTERN =
  /DECISION:\s*\[([^\]]+)\]\s*(?:->|→)\s*\[([^\]]+)\]\s*(?:because\s*)?(.+?)(?=\n(?:DECISION|QUESTION|ASSUMING|FOCUS):|$)/gis;

const QUESTION_PATTERN =
  /QUESTION:\s*(.+?)(?:\nOPTIONS:\s*(.+?))?(?:\nLEANING:\s*(.+?))?(?=\n(?:DECISION|QUESTION|ASSUMING|FOCUS):|$)/gis;

const ASSUMING_PATTERN =
  /ASSUMING:\s*(.+?)(?=\n(?:DECISION|QUESTION|ASSUMING|FOCUS):|$)/gis;

const FOCUS_PATTERN = /FOCUS:\s*(.+?)(?=\n|$)/gi;

// Natural language patterns (fallback detection)
const NATURAL_QUESTION_PATTERNS = [
  /(?:should\s+(?:I|we)\s+)(.+?\?)/gi,
  /(?:do\s+you\s+(?:want|prefer)\s+)(.+?\?)/gi,
  /(?:which\s+(?:approach|option|method)\s+)(.+?\?)/gi,
  /(?:is\s+it\s+(?:okay|fine|acceptable)\s+(?:to|if)\s+)(.+?\?)/gi,
];

const NATURAL_DECISION_PATTERNS = [
  /(?:I(?:'m|'ll| will| am)\s+(?:going to\s+)?(?:use|choose|go with|implement))\s+(.+?)(?:\s+(?:because|since|as)\s+(.+?))?(?:\.|$)/gi,
  /(?:(?:Using|Choosing|Going with|Implementing))\s+(.+?)(?:\s+(?:because|since|as)\s+(.+?))?(?:\.|$)/gi,
];

const NATURAL_ASSUMPTION_PATTERNS = [
  /(?:(?:I(?:'m|'ll| will| am)\s+)?assuming)\s+(.+?)(?:\.|$)/gi,
  /(?:(?:I(?:'ll| will)\s+)?assume)\s+(.+?)(?:\.|$)/gi,
];

export interface ExtractionResult {
  decisions: Decision[];
  questions: Question[];
  assumptions: Assumption[];
  focus?: string;
  remainingBuffer: string;
}

/**
 * Extract structured markers from output text
 */
export function extractFromOutput(
  text: string,
  existingSpec: SessionSpec
): ExtractionResult {
  const decisions: Decision[] = [];
  const questions: Question[] = [];
  const assumptions: Assumption[] = [];
  let focus: string | undefined;

  // Extract structured DECISION markers
  let match;
  while ((match = DECISION_PATTERN.exec(text)) !== null) {
    const [, topic, choice, rationale] = match;
    if (topic && choice) {
      const id = `decision-${randomUUID().slice(0, 8)}`;
      // Check if this decision already exists (by topic + choice)
      const exists = existingSpec.decisions.some(
        (d) =>
          d.topic.toLowerCase() === topic.trim().toLowerCase() &&
          d.choice.toLowerCase() === choice.trim().toLowerCase()
      );
      if (!exists) {
        decisions.push({
          id,
          topic: topic.trim(),
          choice: choice.trim(),
          rationale: rationale?.trim() || "",
          timestamp: new Date(),
          approved: false,
        });
      }
    }
  }

  // Extract structured QUESTION markers
  while ((match = QUESTION_PATTERN.exec(text)) !== null) {
    const [, question, optionsStr, leaning] = match;
    if (question) {
      const id = `question-${randomUUID().slice(0, 8)}`;
      // Check if similar question already exists
      const exists = existingSpec.questions.some(
        (q) => q.question.toLowerCase().includes(question.trim().toLowerCase().slice(0, 50))
      );
      if (!exists) {
        const options = optionsStr
          ? optionsStr.split("|").map((o) => o.trim())
          : undefined;
        questions.push({
          id,
          question: question.trim(),
          options,
          claudeSuggestion: leaning?.trim(),
          status: "open",
          timestamp: new Date(),
        });
      }
    }
  }

  // Extract structured ASSUMING markers
  while ((match = ASSUMING_PATTERN.exec(text)) !== null) {
    const [, assumption] = match;
    if (assumption) {
      const id = `assumption-${randomUUID().slice(0, 8)}`;
      // Check if similar assumption already exists
      const exists = existingSpec.assumptions.some(
        (a) => a.text.toLowerCase().includes(assumption.trim().toLowerCase().slice(0, 50))
      );
      if (!exists) {
        assumptions.push({
          id,
          text: assumption.trim(),
          flagged: false,
          timestamp: new Date(),
        });
      }
    }
  }

  // Extract FOCUS
  const focusMatch = FOCUS_PATTERN.exec(text);
  if (focusMatch) {
    focus = focusMatch[1].trim();
  }

  // Also detect natural language patterns (less reliable, but useful)
  // Only use these if we didn't find structured markers
  if (decisions.length === 0 && questions.length === 0 && assumptions.length === 0) {
    // Natural questions
    for (const pattern of NATURAL_QUESTION_PATTERNS) {
      while ((match = pattern.exec(text)) !== null) {
        const [, question] = match;
        if (question && question.length > 10) {
          const id = `question-${randomUUID().slice(0, 8)}`;
          const exists = existingSpec.questions.some(
            (q) => q.question.toLowerCase().includes(question.trim().toLowerCase().slice(0, 30))
          );
          if (!exists && questions.length < 3) {
            // Limit natural language detections
            questions.push({
              id,
              question: question.trim(),
              status: "open",
              timestamp: new Date(),
            });
          }
        }
      }
    }

    // Natural decisions
    for (const pattern of NATURAL_DECISION_PATTERNS) {
      while ((match = pattern.exec(text)) !== null) {
        const [, choice, rationale] = match;
        if (choice && choice.length > 5) {
          const id = `decision-${randomUUID().slice(0, 8)}`;
          const exists = existingSpec.decisions.some(
            (d) => d.choice.toLowerCase().includes(choice.trim().toLowerCase().slice(0, 30))
          );
          if (!exists && decisions.length < 3) {
            decisions.push({
              id,
              topic: "implementation",
              choice: choice.trim(),
              rationale: rationale?.trim() || "",
              timestamp: new Date(),
              approved: false,
            });
          }
        }
      }
    }

    // Natural assumptions
    for (const pattern of NATURAL_ASSUMPTION_PATTERNS) {
      while ((match = pattern.exec(text)) !== null) {
        const [, assumption] = match;
        if (assumption && assumption.length > 10) {
          const id = `assumption-${randomUUID().slice(0, 8)}`;
          const exists = existingSpec.assumptions.some(
            (a) => a.text.toLowerCase().includes(assumption.trim().toLowerCase().slice(0, 30))
          );
          if (!exists && assumptions.length < 3) {
            assumptions.push({
              id,
              text: assumption.trim(),
              flagged: false,
              timestamp: new Date(),
            });
          }
        }
      }
    }
  }

  // Calculate remaining buffer (last incomplete line)
  const lines = text.split("\n");
  const lastLine = lines[lines.length - 1];
  const remainingBuffer = lastLine.endsWith("\n") ? "" : lastLine;

  return {
    decisions,
    questions,
    assumptions,
    focus,
    remainingBuffer,
  };
}

/**
 * Apply extraction result to a spec
 */
export function applyExtractionToSpec(
  spec: SessionSpec,
  extraction: ExtractionResult
): SessionSpec {
  return {
    ...spec,
    decisions: [...spec.decisions, ...extraction.decisions],
    questions: [...spec.questions, ...extraction.questions],
    assumptions: [...spec.assumptions, ...extraction.assumptions],
    currentFocus: extraction.focus ?? spec.currentFocus,
    outputBuffer: extraction.remainingBuffer,
    lastUpdated: new Date(),
    // If there are new questions, mark as potentially blocked
    blockedOn:
      extraction.questions.length > 0
        ? extraction.questions[0].id
        : spec.blockedOn,
  };
}

/**
 * Classify a question to determine if it should be surfaced to the user
 * Returns: "surface" | "auto-answer" | "skip"
 */
export function classifyQuestion(
  question: Question
): "surface" | "auto-answer" | "skip" {
  const q = question.question.toLowerCase();

  // Questions about user preference/intent -> always surface
  if (
    q.includes("should i") ||
    q.includes("do you prefer") ||
    q.includes("do you want") ||
    q.includes("which approach") ||
    q.includes("which option") ||
    q.includes("is it okay") ||
    q.includes("is this correct")
  ) {
    return "surface";
  }

  // Questions about file locations or simple facts -> might be auto-answerable
  if (
    q.includes("where is") ||
    q.includes("what is the path") ||
    q.includes("what file") ||
    q.includes("which directory")
  ) {
    return "auto-answer";
  }

  // Questions with options provided -> surface for human decision
  if (question.options && question.options.length > 1) {
    return "surface";
  }

  // Default to surfacing (safer)
  return "surface";
}
