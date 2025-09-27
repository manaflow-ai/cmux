import { z } from "zod";

export const CrownEvaluationCandidateSchema = z.object({
  runId: z.string(),
  agentName: z.string(),
  gitDiff: z.string(),
});

export type CrownEvaluationCandidate = z.infer<
  typeof CrownEvaluationCandidateSchema
>;

export function buildEvaluationPrompt(
  taskText: string,
  candidates: CrownEvaluationCandidate[]
): string {
  const evaluationData = {
    task: taskText,
    implementations: candidates.map((candidate, index) => ({
      modelName: candidate.agentName,
      gitDiff: candidate.gitDiff,
      index,
    })),
  };

  return `You are evaluating code implementations from different AI models.\n\nHere are the implementations to evaluate:\n${JSON.stringify(
    evaluationData,
    null,
    2
  )}\n\nNOTE: The git diffs shown contain only actual code changes. Lock files, build artifacts, and other non-essential files have been filtered out.\n\nAnalyze these implementations and select the best one based on:\n1. Code quality and correctness\n2. Completeness of the solution\n3. Following best practices\n4. Actually having meaningful code changes (if one has no changes, prefer the one with changes)\n\nRespond with a JSON object containing:\n- "winner": the index (0-based) of the best implementation\n- "reason": a brief explanation of why this implementation was chosen\n\nExample response:\n{"winner": 0, "reason": "Model claude/sonnet-4 provided a more complete implementation with better error handling and cleaner code structure."}\n\nIMPORTANT: Respond ONLY with the JSON object, no other text.`;
}

export function buildSummarizationPrompt(
  taskText: string,
  gitDiff: string
): string {
  return `You are an expert reviewer summarizing a pull request.\n\nGOAL\n- Explain succinctly what changed and why.\n- Call out areas the user should review carefully.\n- Provide a quick test plan to validate the changes.\n\nCONTEXT\n- User's original request:\n${taskText}\n- Relevant diffs (unified):\n${gitDiff || "<no code changes captured>"}\n\nINSTRUCTIONS\n- Base your summary strictly on the provided diffs and request.\n- Be specific about files and functions when possible.\n- Prefer clear bullet points over prose. Keep it under ~300 words.\n- If there are no code changes, say so explicitly and suggest next steps.\n\nOUTPUT FORMAT (Markdown)\n## PR Review Summary\n- What Changed: bullet list\n- Review Focus: bullet list (risks/edge cases)\n- Test Plan: bullet list of practical steps\n- Follow-ups: optional bullets if applicable\n`;
}
