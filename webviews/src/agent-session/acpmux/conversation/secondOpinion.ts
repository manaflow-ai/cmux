import { createContext } from "react";

/** Launches a read-only guest against the current thread's plan or diff. */
export const SecondOpinionContext = createContext<((rowId: string, files: readonly string[]) => void) | undefined>(
  undefined,
);
