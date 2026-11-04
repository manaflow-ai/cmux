import { openSubagentPane } from "./subagents/subagentPanes";

// A reserved reveal opens an existing session in a new native tab without starting a harness.
export const CONTEXT_PANE = "cmux:context";
export const isContextPane = (id: string | undefined) => id === CONTEXT_PANE;

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

export const openContextPane = (call: Call, title: string) => openSubagentPane(call, CONTEXT_PANE, true, title);
