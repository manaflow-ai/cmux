import { externalAccessFromRequest } from "../permissions/externalAccess";
import type { AcpmuxFileDiff, AcpmuxPermission, AcpmuxPermissionScope } from "../model";
import { questionFromPermission } from "../question/model";
import { translate } from "../i18n";
import { objectValue, stringValue, toolDiffs, inputDiffs, shellCommand } from "./toolItems";

/** Keep only the stable ACP subject fields that make an approval's target legible. */
function permissionScopeFromMessage(raw: any, toolCall: any): AcpmuxPermissionScope | undefined {
  const subject = objectValue(raw?.subject);
  const subjectTool = subject?.type === "tool_call" ? objectValue(subject.toolCall) : undefined;
  const call = subjectTool ?? objectValue(toolCall);
  const input = objectValue(call?.rawInput);
  const app = stringValue(input?.app) ?? stringValue(input?.application) ?? stringValue(input?.appName);
  if (app) return { kind: "app", value: app };
  const locations = (Array.isArray(call?.locations) ? call.locations : [])
    .map((location: unknown) => stringValue(objectValue(location)?.path))
    .filter((path: string | undefined): path is string => path !== undefined);
  const resource = locations[0] ?? stringValue(input?.file_path) ?? stringValue(input?.path) ?? stringValue(input?.url);
  if (resource && call?.kind !== "execute") return { kind: "resource", value: resource };
  const cwd = (subject?.type === "command" ? stringValue(subject.cwd) : undefined) ?? stringValue(input?.cwd);
  return cwd ? { kind: "directory", value: cwd } : undefined;
}

export function permissionFromMessage(message: any, selectedSessionId: string): AcpmuxPermission | undefined {
  const envelope = message ?? {};
  const raw = envelope?.request ?? envelope;
  const sessionId = envelope?.sessionId ?? raw?.sessionId;
  const permissionId = envelope?.permissionId ?? raw?.permissionId;
  if (!permissionId || sessionId !== selectedSessionId) return undefined;
  const question = questionFromPermission({
    permissionId: String(permissionId),
    session: sessionId,
    request: raw,
  });
  const claudeMeta =
    raw.toolCall?._meta?.claude && typeof raw.toolCall._meta.claude === "object"
      ? raw.toolCall._meta.claude
      : undefined;
  const subject = objectValue(raw.subject);
  const subjectTool = subject?.type === "tool_call" ? objectValue(subject.toolCall) : undefined;
  const subjectCommand = subject?.type === "command" ? subject : undefined;
  const toolCall = raw.toolCall ?? subjectTool;
  const suggestions = Array.isArray(claudeMeta?.suggestions)
    ? claudeMeta.suggestions.flatMap((suggestion: unknown) => {
        if (typeof suggestion === "string" && suggestion.trim()) return [suggestion.trim()];
        if (!suggestion || typeof suggestion !== "object") return [];
        const rules = (suggestion as { rules?: unknown }).rules;
        return Array.isArray(rules)
          ? rules.flatMap((rule: unknown) => {
              if (typeof rule === "string" && rule.trim()) return [rule.trim()];
              if (!rule || typeof rule !== "object") return [];
              const value = rule as { toolName?: unknown; ruleContent?: unknown };
              const tool = typeof value.toolName === "string" ? value.toolName.trim() : "";
              const content = typeof value.ruleContent === "string" ? value.ruleContent.trim() : "";
              return [content || tool].filter(Boolean);
            })
          : [];
      })
    : [];
  return {
    ...(question ? { question } : {}),
    permissionId: String(permissionId),
    groupId: typeof envelope.groupId === "string" ? envelope.groupId : undefined,
    turnId: typeof envelope.turnId === "string" ? envelope.turnId : undefined,
    // ACP v2's request title names the approval itself; a subject tool title is its operation fallback.
    title: raw.title ?? toolCall?.title,
    // A string, or an argv array read the way the transcript's Shell block reads it (`sh -lc` unwrapped).
    command:
      typeof toolCall?.command === "string"
        ? toolCall.command
        : (shellCommand(toolCall?.rawInput) ??
          stringValue(subjectCommand?.command) ??
          (typeof raw.command === "string" ? raw.command : undefined)),
    description:
      typeof claudeMeta?.description === "string"
        ? claudeMeta.description
        : typeof toolCall?.description === "string"
          ? toolCall.description
          : typeof raw.description === "string"
            ? raw.description
            : undefined,
    rule:
      suggestions.length > 0
        ? translate("permission.claude.alwaysAllowRule", { rules: suggestions.join(", ") })
        : typeof toolCall?.rule === "string"
          ? toolCall.rule
          : typeof raw.rule === "string"
            ? raw.rule
            : undefined,
    kind: toolCall?.kind ?? (subjectCommand ? "execute" : undefined),
    ...(typeof toolCall?.toolCallId === "string" ? { toolCallId: toolCall.toolCallId } : {}),
    scope: permissionScopeFromMessage(raw, toolCall),
    externalAccess: externalAccessFromRequest(raw),
    diffs: permissionDiffs(toolCall),
    plan: permissionPlan(toolCall, claudeMeta),
    ...(claudeMeta?.tool === "ExitPlanMode" && typeof objectValue(toolCall?.rawInput)?.plan === "string"
      ? { planEditable: true }
      : {}),
    pending: true,
    options: (raw.options ?? []).map((option: any) => ({
      id: String(option.optionId ?? option.id),
      name: String(option.name ?? option.optionId),
      allow: String(option.kind ?? "").startsWith("allow"),
      kind: typeof option.kind === "string" ? option.kind : undefined,
      description: typeof option.description === "string" ? option.description : undefined,
      rule:
        typeof option.rule === "string"
          ? option.rule
          : typeof option.suggestion === "string"
            ? option.suggestion
            : undefined,
    })),
  };
}

/// The ask's proposed edits. Explicit ACP diffs win over input fragments, including acpmux's Write
/// fragment with no old text, which shows the text the Write will put there (`toolFiles`). An edit
/// tool's input is read only when no diff came: there a Write's content is left out, since before
/// approval there is no result proving it creates a new file.
export function permissionDiffs(
  tool: { kind?: unknown; content?: unknown; locations?: unknown; rawInput?: unknown } | undefined,
): AcpmuxFileDiff[] | undefined {
  return toolDiffs(tool?.content, tool?.locations) ?? (tool?.kind === "edit" ? inputDiffs(tool.rawInput) : undefined);
}

/// The plan a plan approval asks about: one acpmux attached (`_meta.acpmux.plan.markdown`, as for
/// Gemini's plan file), Claude Code's ExitPlanMode input `plan`, or the plan acpmux puts in a
/// `switch_mode` ask it builds from Grok's and Cursor's own plan approvals (hub xai.rs,
/// cursor_ext.rs), from its input or else its text content. Undefined for any other ask, and for a
/// plan approval with no plan text.
export function permissionPlan(
  tool: { kind?: unknown; content?: unknown; rawInput?: unknown; _meta?: unknown } | undefined,
  claudeMeta?: { tool?: unknown },
): string | undefined {
  const attached = stringValue(objectValue(objectValue(objectValue(tool?._meta)?.acpmux)?.plan)?.markdown)?.trim();
  if (attached) return attached;
  if (claudeMeta?.tool !== "ExitPlanMode" && tool?.kind !== "switch_mode") return undefined;
  const input = stringValue(objectValue(tool?.rawInput)?.plan)?.trim();
  if (input) return input;
  const text = Array.isArray(tool?.content)
    ? tool.content
        .map((item: any) => (item?.type === "content" && item.content?.type === "text" ? item.content.text : ""))
        .filter((part: unknown): part is string => typeof part === "string" && part.trim() !== "")
        .join("\n\n")
        .trim()
    : "";
  return text || undefined;
}
