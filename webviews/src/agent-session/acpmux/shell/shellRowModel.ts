import { createContext } from "react";
import type { ShellRun } from "./shellRuns";

/// Lines of output a closed block shows: the last ones, where results and errors are.
export const SHELL_COLLAPSED_LINES = 8;

export type ShellActions = { stop(id: string): void; openInTerminal(run: ShellRun): void };
export const ShellActionsContext = createContext<ShellActions | undefined>(undefined);
