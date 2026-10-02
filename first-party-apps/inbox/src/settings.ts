/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// App settings (`contributes.settings`, owned by the config layer; read-only here).

import type { GithubOptions } from "./github.ts"

export type Variant = "grouped" | "focus" | "card"
export const VARIANTS: readonly Variant[] = ["grouped", "focus", "card"]
export const DEFAULT_VARIANT: Variant = "grouped"

export interface Settings {
  variant: Variant
  groupBy: "source" | "workspace"
  includeIdleAgents: boolean
  includeDoneAgents: boolean
  maxAgeDays: number
  github: GithubOptions & { enabled: boolean; refreshMinutes: number }
}

const bool = (v: unknown, fallback: boolean) => (typeof v === "boolean" ? v : fallback)
const num = (v: unknown, fallback: number, min: number, max: number) => (typeof v === "number" && Number.isFinite(v) ? Math.min(max, Math.max(min, v)) : fallback)

export const asVariant = (v: unknown): Variant => (VARIANTS.includes(v as Variant) ? (v as Variant) : DEFAULT_VARIANT)

/** Normalizes raw settings (missing or malformed keys get their documented defaults). */
export function readSettings(raw: Record<string, unknown>): Settings {
  const reviewRequests = bool(raw.githubReviewRequests, true)
  const failingChecks = bool(raw.githubFailingChecks, true)
  const mentions = bool(raw.githubMentions, true)
  return {
    variant: asVariant(raw.variant),
    groupBy: raw.groupBy === "workspace" ? "workspace" : "source",
    includeIdleAgents: bool(raw.includeIdleAgents, false),
    includeDoneAgents: bool(raw.includeDoneAgents, true),
    maxAgeDays: num(raw.maxAgeDays, 7, 0, 365),
    github: {
      enabled: reviewRequests || failingChecks || mentions,
      reviewRequests,
      failingChecks,
      mentions,
      mentionDays: num(raw.maxAgeDays, 7, 1, 365),
      refreshMinutes: num(raw.githubRefreshMinutes, 10, 2, 240)
    }
  }
}

export const settings = (): Settings => readSettings(cmux.app.settings())
