/**
 * Protocol Markers for Orchestrated Claude Code Sessions
 *
 * This protocol enables the orchestrator to extract structured information
 * from Claude Code's natural conversation, without requiring Claude Code
 * to maintain a separate spec file.
 */

/**
 * The protocol prompt to prepend to tasks when orchestration is enabled
 */
export const ORCHESTRATION_PROTOCOL = `
## Orchestration Protocol

You are being monitored by an orchestrator that helps humans stay in the loop.
Use these lightweight markers in your output so the orchestrator can extract key information:

**When you make a significant decision:**
\`\`\`
DECISION: [topic] -> [choice] because [rationale]
\`\`\`
Example: DECISION: [hashing algorithm] -> [bcrypt] because simpler and sufficient for our scale

**When you need human input (unclear requirements, multiple valid approaches, etc.):**
\`\`\`
QUESTION: [your question]
OPTIONS: [option1] | [option2] | [option3]
LEANING: [your suggestion] because [why]
\`\`\`
Example:
QUESTION: Should sessions use JWT or cookies?
OPTIONS: JWT (stateless) | Cookies (simpler)
LEANING: Cookies because simpler for MVP, avoids refresh token complexity

**When you make an assumption that the human should know about:**
\`\`\`
ASSUMING: [what you're assuming]
\`\`\`
Example: ASSUMING: 24 hour session expiry is acceptable

**When your focus changes to a new task area:**
\`\`\`
FOCUS: [what you're working on now]
\`\`\`
Example: FOCUS: Implementing password hashing

**Guidelines:**
- Use markers sparingly - only for significant decisions, not every tiny choice
- Keep working even if you haven't heard back on a QUESTION - don't block yourself
- If you're 80%+ confident on a decision, just note it with DECISION and continue
- Use QUESTION only when genuinely uncertain about user intent or when there are multiple valid approaches

The orchestrator will surface important questions to the human and auto-answer trivial ones.
Continue to work normally - these markers are just annotations on your natural workflow.
`;

/**
 * Lighter version for workspaces that already have extensive CLAUDE.md
 */
export const ORCHESTRATION_PROTOCOL_MINIMAL = `
## Orchestration Markers

Use these markers occasionally so the human can track your progress:

- \`DECISION: [topic] -> [choice] because [reason]\` - when making significant choices
- \`QUESTION: [question] OPTIONS: [opt1] | [opt2] LEANING: [suggestion]\` - when you need input
- \`ASSUMING: [assumption]\` - when making assumptions the human should know
- \`FOCUS: [current task]\` - when changing focus areas

Only use for significant items. Continue working naturally.
`;

/**
 * Generate a CLAUDE.md snippet for repos that want orchestration
 */
export function generateClaudeMdSnippet(): string {
  return `
# Orchestration Integration

${ORCHESTRATION_PROTOCOL_MINIMAL}
`;
}

/**
 * Wrap a user prompt with the orchestration protocol
 */
export function wrapPromptWithProtocol(userPrompt: string): string {
  return `${ORCHESTRATION_PROTOCOL}

---

## Your Task

${userPrompt}`;
}

/**
 * Check if a prompt already has orchestration protocol
 */
export function hasProtocol(text: string): boolean {
  return (
    text.includes("DECISION:") ||
    text.includes("QUESTION:") ||
    text.includes("ASSUMING:") ||
    text.includes("Orchestration Protocol") ||
    text.includes("Orchestration Markers")
  );
}
