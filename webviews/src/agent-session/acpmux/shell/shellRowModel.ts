import { createContext } from "react";
import type { ShellRun } from "./shellRuns";

export type ShellActions = { stop(id: string): void; openInTerminal(run: ShellRun): void };
export const ShellActionsContext = createContext<ShellActions | undefined>(undefined);
