import { escapeMarkdownDestination, escapeMarkdownLabel } from "./markdownEscapes";

export type PromptMentionText = {
  displayName?: string;
  kind: "at" | "agent" | "skill";
  label?: string;
  name: string;
  path: string;
};

export function promptMentionMarkdown(mention: PromptMentionText): string {
  switch (mention.kind) {
    case "at":
      return markdownLink(mention.label ?? mention.name, mention.path);
    case "agent":
      return markdownLink(`@${mention.displayName || mention.name}`, mention.path);
    case "skill":
      return markdownLink(`$${mention.name}`, mention.path);
  }
}

export function promptTextWithAutoContext(input: string, mention: PromptMentionText | null, enabled: boolean): string {
  if (!enabled || mention == null) {
    return input;
  }
  const contextText = promptMentionMarkdown(mention);
  if (input.includes(contextText) || input.includes(mention.path)) {
    return input;
  }
  return input.trim().length > 0 ? `${contextText}\n\n${input}` : contextText;
}

function markdownLink(label: string, destination: string): string {
  return `[${escapeMarkdownLabel(label)}](${escapeMarkdownDestination(destination)})`;
}
