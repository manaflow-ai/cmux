"use client";

import { createContext, useContext } from "react";

/** Lets the server-streamed roster hand a picked row to the search panel. */
export const AdminSearchContext = createContext<{ pickQuery: (query: string) => void } | null>(null);

export function useAdminSearch(): { pickQuery: (query: string) => void } | null {
  return useContext(AdminSearchContext);
}
