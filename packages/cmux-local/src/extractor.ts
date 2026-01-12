/**
 * Extract questions, decisions, and other structured data from Claude Code output
 *
 * Uses the Orchestration Protocol markers:
 * - DECISION: [topic] -> [choice] because [reason]
 * - QUESTION: [question] OPTIONS: [opt1] | [opt2] LEANING: [suggestion]
 * - ASSUMING: [assumption]
 * - FOCUS: [what working on]
 */

import { nanoid } from "nanoid";
import { type Question } from "./types.js";

// ─────────────────────────────────────────────────────────────
// Regex patterns for structured markers (from orchestrator)
// ─────────────────────────────────────────────────────────────

const DECISION_PATTERN =
  /DECISION:\s*\[([^\]]+)\]\s*(?:->|→)\s*\[([^\]]+)\]\s*(?:because\s*)?(.+?)(?=\n(?:DECISION|QUESTION|ASSUMING|FOCUS):|$)/gis;

const QUESTION_PATTERN =
  /QUESTION:\s*(.+?)(?:\nOPTIONS:\s*(.+?))?(?:\nLEANING:\s*(.+?))?(?=\n(?:DECISION|QUESTION|ASSUMING|FOCUS):|$)/gis;

const ASSUMING_PATTERN =
  /ASSUMING:\s*(.+?)(?=\n(?:DECISION|QUESTION|ASSUMING|FOCUS):|$)/gis;

const FOCUS_PATTERN = /FOCUS:\s*(.+?)(?=\n|$)/gi;

// ─────────────────────────────────────────────────────────────
// Protocol example text to filter out (these are from the ORCHESTRATION_PROTOCOL)
// ─────────────────────────────────────────────────────────────

const PROTOCOL_EXAMPLES = [
  // Template placeholders
  "[your question]",
  "[topic]",
  "[choice]",
  "[rationale]",
  "[option1]",
  "[option2]",
  "[option3]",
  "[your suggestion]",
  "[why]",
  "[what you're assuming]",
  "[what you're working on now]",
  // Actual examples from protocol
  "should sessions use jwt or cookies",
  "jwt (stateless) | cookies (simpler)",
  "cookies because simpler for mvp",
  "hashing algorithm",
  "bcrypt",
  "24 hour session expiry",
  "implementing password hashing",
  "simpler and sufficient for our scale",
];

/**
 * Check if text is a protocol example that should be filtered out
 */
function _isProtocolExample(text: string): boolean {
  const lower = text.toLowerCase();
  return PROTOCOL_EXAMPLES.some((example) => lower.includes(example));
}

// Natural language patterns (fallback detection)
// These capture the FULL question including the prefix for proper context
const NATURAL_QUESTION_PATTERNS = [
  /(should\s+(?:I|we)\s+.+?\?)/gi,
  /(do\s+you\s+(?:want|prefer)\s+.+?\?)/gi,
  /(which\s+(?:approach|option|method)\s+.+?\?)/gi,
  /(is\s+it\s+(?:okay|fine|acceptable)\s+(?:to|if)\s+.+?\?)/gi,
  /(would\s+you\s+(?:like|prefer)\s+.+?\?)/gi,
];

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

export interface Decision {
  id: string;
  topic: string;
  choice: string;
  rationale: string;
  timestamp: Date;
}

export interface Assumption {
  id: string;
  text: string;
  timestamp: Date;
}

export interface ExtractionResult {
  questions: Question[];
  decisions: Decision[];
  assumptions: Assumption[];
  focus: string | null;
  status: "idle" | "working" | "waiting" | "done";
}

// ─────────────────────────────────────────────────────────────
// Main extraction function
// ─────────────────────────────────────────────────────────────

export function extractQuestionsFromOutput(
  output: string,
  taskId: string
): ExtractionResult {
  const questions: Question[] = [];
  const decisions: Decision[] = [];
  const assumptions: Assumption[] = [];
  let focus: string | null = null;
  let status: ExtractionResult["status"] = "working";

  // Extract structured DECISION markers
  let match;
  const decisionPattern = new RegExp(DECISION_PATTERN.source, DECISION_PATTERN.flags);
  while ((match = decisionPattern.exec(output)) !== null) {
    const [, topic, choice, rationale] = match;
    if (topic && choice) {
      decisions.push({
        id: nanoid(8),
        topic: topic.trim(),
        choice: choice.trim(),
        rationale: rationale?.trim() || "",
        timestamp: new Date(),
      });
    }
  }

  // Extract structured QUESTION markers
  const questionPattern = new RegExp(QUESTION_PATTERN.source, QUESTION_PATTERN.flags);
  while ((match = questionPattern.exec(output)) !== null) {
    const [, question, optionsStr, leaning] = match;
    if (question) {
      const options = optionsStr
        ? optionsStr.split("|").map((o) => o.trim())
        : undefined;
      questions.push({
        id: nanoid(8),
        taskId,
        question: question.trim(),
        options,
        suggestion: leaning?.trim(),
        status: "open",
        askedAt: new Date(),
      });
    }
  }

  // Extract structured ASSUMING markers
  const assumingPattern = new RegExp(ASSUMING_PATTERN.source, ASSUMING_PATTERN.flags);
  while ((match = assumingPattern.exec(output)) !== null) {
    const [, assumption] = match;
    if (assumption) {
      assumptions.push({
        id: nanoid(8),
        text: assumption.trim(),
        timestamp: new Date(),
      });
    }
  }

  // Extract FOCUS
  const focusPattern = new RegExp(FOCUS_PATTERN.source, FOCUS_PATTERN.flags);
  const focusMatch = focusPattern.exec(output);
  if (focusMatch) {
    focus = focusMatch[1].trim();
  }

  // Fallback: Natural language question detection (only if no structured questions found)
  if (questions.length === 0) {
    for (const pattern of NATURAL_QUESTION_PATTERNS) {
      const naturalPattern = new RegExp(pattern.source, pattern.flags);
      while ((match = naturalPattern.exec(output)) !== null) {
        // match[1] now contains the full question including prefix
        const fullQuestion = match[1];
        if (fullQuestion && fullQuestion.length > 10 && fullQuestion.length < 300) {
          // Avoid duplicates
          const exists = questions.some(
            (q) => q.question.toLowerCase() === fullQuestion.trim().toLowerCase()
          );
          if (!exists && questions.length < 3) {
            questions.push({
              id: nanoid(8),
              taskId,
              question: fullQuestion.trim(),
              status: "open",
              askedAt: new Date(),
            });
          }
        }
      }
    }
  }

  // Detect waiting for input state
  if (
    output.includes("waiting for") ||
    output.includes("press enter") ||
    output.includes("type your") ||
    output.match(/>\s*$/) ||
    questions.length > 0
  ) {
    status = "waiting";
  }

  // Detect completion
  if (
    output.includes("Task completed") ||
    output.includes("Done!") ||
    output.includes("Finished") ||
    output.includes("All tasks complete")
  ) {
    status = "done";
  }

  return { questions, decisions, assumptions, focus, status };
}

/**
 * Extract a summary of what Claude is currently doing
 */
export function extractCurrentActivity(output: string): string | null {
  // Get the last ~30 lines to find current activity
  const lines = output.split("\n").slice(-30);
  const recentOutput = lines.join("\n");

  // Check for FOCUS marker first (most reliable)
  const focusMatch = recentOutput.match(/FOCUS:\s*(.+?)(?=\n|$)/i);
  if (focusMatch) {
    return focusMatch[1].trim().slice(0, 50);
  }

  // Look for tool usage indicators
  if (recentOutput.includes("Read(") || recentOutput.includes("Reading")) {
    const match = recentOutput.match(/(?:Read\(|Reading)\s*['"]?([^'")\n]+)/i);
    return match ? `Reading ${match[1].slice(0, 30)}...` : "Reading files...";
  }

  if (recentOutput.includes("Edit(") || recentOutput.includes("Write(") || recentOutput.includes("Writing")) {
    const match = recentOutput.match(/(?:Edit\(|Write\(|Writing)\s*['"]?([^'")\n]+)/i);
    return match ? `Editing ${match[1].slice(0, 30)}...` : "Editing files...";
  }

  if (recentOutput.includes("Bash(") || recentOutput.includes("Running")) {
    return "Running command...";
  }

  if (recentOutput.includes("Grep(") || recentOutput.includes("Glob(") || recentOutput.includes("Searching")) {
    return "Searching codebase...";
  }

  if (recentOutput.includes("Task(") || recentOutput.includes("Agent")) {
    return "Running sub-agent...";
  }

  // Look for thinking indicators
  if (recentOutput.includes("thinking") || recentOutput.includes("...")) {
    return "Thinking...";
  }

  // Look for spinner/progress indicators
  if (recentOutput.match(/[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏●○◐◑◒◓]/)) {
    return "Working...";
  }

  return null;
}

/**
 * Classify a question to determine if it should be surfaced to the user
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
