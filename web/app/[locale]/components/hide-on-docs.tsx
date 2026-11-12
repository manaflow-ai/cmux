"use client";

import { useSelectedLayoutSegment } from "next/navigation";
import type { ReactNode } from "react";

/**
 * Hides shared landing chrome on docs routes. The docs layout renders the
 * footer inside its content column so the fixed sidebar never overlaps it.
 */
export function HideOnDocs({ children }: { children: ReactNode }) {
  return useSelectedLayoutSegment() === "docs" ? null : children;
}
