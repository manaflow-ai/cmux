"use client";

import { createContext, useContext } from "react";
import type { DocsChannel } from "@/app/lib/docs-channel";

const DocsChannelContext = createContext<DocsChannel>("release");

export const DocsChannelProvider = DocsChannelContext.Provider;

export function useDocsChannel(): DocsChannel {
  return useContext(DocsChannelContext);
}
