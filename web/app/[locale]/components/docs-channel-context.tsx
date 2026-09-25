"use client";

import { createContext, use } from "react";
import type { DocsChannel } from "@/app/lib/docs-channel";

const DocsChannelContext = createContext<DocsChannel>("release");

export const DocsChannelProvider = DocsChannelContext.Provider;

export function useDocsChannel(): DocsChannel {
  return use(DocsChannelContext);
}
