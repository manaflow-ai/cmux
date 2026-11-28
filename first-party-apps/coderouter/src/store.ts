// App-wide state shared by every mount and command in this app's VM:
// onboarding progress, the last test, the key just created, busy flags, a
// short notice, and the design variant. Persisted parts live in
// cmux.storage; nothing persisted is secret.

import { setLocale } from "./l10n.ts"
import type { KeyCreated, TestResult } from "./model.ts"
import { initialProgress, parseProgress, reduce, type Facts, type OnboardingEvent, type Progress } from "./onboarding.ts"
import { OP, isUnsupported } from "./ops.ts"

export const STORAGE = { onboarding: "onboarding", lastTest: "lastTest" } as const

// MARK: Variant

export const VARIANTS = ["checklist", "wizard", "tabs"] as const
export type Variant = (typeof VARIANTS)[number]
export const DEFAULT_VARIANT: Variant = "checklist"

const [variantOverride, setVariantOverride] = signal<Variant | null>(null)

export function variant(): Variant {
  const o = variantOverride()
  if (o) return o
  const v = cmux.app.settings().variant
  return (VARIANTS as readonly unknown[]).includes(v) ? (v as Variant) : DEFAULT_VARIANT
}

export const nextVariant = (v: Variant): Variant => VARIANTS[(VARIANTS.indexOf(v) + 1) % VARIANTS.length]!

/** Writes the setting when the host can (proposed `app.settings.set`); otherwise switches for this session only. */
export async function cycleVariant(): Promise<Variant> {
  const next = nextVariant(variant())
  setVariantOverride(next)
  try {
    await cmux.call(OP.setSetting, { key: "variant", value: next })
  } catch (e) {
    if (!isUnsupported(e)) cmux.log("variant setting not saved:", String(e))
  }
  return next
}

/** Applies the language: the dev-only override, else the host's locale when it passes one, else English. */
export function applyLocale(ctx: { locale?: unknown } = {}) {
  const override = cmux.app.settings().language
  setLocale(override && override !== "auto" ? String(override) : typeof ctx.locale === "string" ? ctx.locale : "en")
}

// MARK: Onboarding progress

const [progress, setProgress] = signal<Progress>(initialProgress())
const [progressLoaded, setProgressLoaded] = signal(false)
let loading: Promise<void> | null = null

export { progress, progressLoaded }

export function loadProgress(): Promise<void> {
  loading ??= Promise.all([cmux.storage.get(STORAGE.onboarding).catch(() => null), cmux.storage.get(STORAGE.lastTest).catch(() => null)]).then(([p, last]) => {
    setProgress(parseProgress(p))
    if (last && typeof last === "object") setLastTest(last as TestResult)
    setProgressLoaded(true)
  })
  return loading
}

export function onboard(event: OnboardingEvent, facts: Facts): Progress {
  const next = reduce(progress(), event, facts, Date.now())
  setProgress(next)
  cmux.storage.set(STORAGE.onboarding, next).catch((e: unknown) => cmux.log("onboarding progress not saved:", String(e)))
  return next
}

// MARK: Session state

export const [lastTest, setLastTest] = signal<TestResult | null>(null)
export const [createdKey, setCreatedKey] = signal<KeyCreated | null>(null)

const [busySet, setBusySet] = signal<ReadonlySet<string>>(new Set())
export const isBusy = (key: string) => busySet().has(key)

export async function withBusy<T>(key: string, fn: () => Promise<T>): Promise<T> {
  setBusySet((s) => new Set([...s, key]))
  try {
    return await fn()
  } finally {
    setBusySet((s) => new Set([...s].filter((k) => k !== key)))
  }
}

export interface Notice {
  tone: "success" | "warning" | "danger" | "secondary"
  text: string
}

export const [notice, setNoticeSignal] = signal<Notice | null>(null)
let noticeTimer: number | null = null

/** Shows one line under the content; it clears itself after a few seconds (one-shot timer). */
export function say(tone: Notice["tone"], text: string) {
  setNoticeSignal({ tone, text })
  if (noticeTimer !== null) cmux.timer.clear(noticeTimer)
  noticeTimer = cmux.timer.after(6000, () => {
    noticeTimer = null
    setNoticeSignal(null)
  })
}
