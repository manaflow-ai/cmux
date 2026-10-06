// Placeholder: the thread widget contract checks are not implemented yet (schemas/widgets).
import settingsSchema from "../../../../../../schemas/widgets/settings.schema.json";

export type ContractError = "schema" | "too_large";
export type ContractIssue = { error: ContractError; path: string; message: string };

export function validateWidgetContract(_target: string, _value: unknown): ContractIssue[] {
  return [];
}

export async function codeWidgetDigestMatches(_spec: { html: string; sha256: string }): Promise<boolean> {
  return true;
}

export type PatchOperation =
  | { op: "set"; path: string; value: unknown }
  | { op: "append"; path: string; values: unknown[]; keepLast?: number }
  | { op: "remove"; path: string; where?: { field: string; equals: unknown } };

export type PatchResult = { ok: true; data: unknown } | { ok: false; op: number; reason: string };

export function applyDataPatch(data: unknown, _patch: readonly PatchOperation[], _dataSchema?: string): PatchResult {
  return { ok: true, data };
}

export type CodeWidgetsSetting = "on" | "off";
export const codeWidgetsDefault = settingsSchema.properties["agentPane.widgets.code"].default as CodeWidgetsSetting;

export type WidgetPolicyInput = {
  kind: string;
  code: CodeWidgetsSetting;
  pane: "local" | "paired" | "cloud" | "web";
  quarantined: boolean;
};
export type WidgetPolicy = { render: "native" | "sandbox" | "source"; capabilities: boolean };

export function widgetPolicy(_input: WidgetPolicyInput): WidgetPolicy {
  return { render: "native", capabilities: false };
}
