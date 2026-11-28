// Three layouts of the same five setup steps:
//   wizard     one step per screen with Back / Skip / Continue (onboarding pane)
//   checklist  five rows; the open one expands in place (sidebar section)
//   page       every step on one page with a progress bar (tabs variant)

import { openPane, signIn } from "../actions.ts"
import type { Core } from "../data.ts"
import { t } from "../l10n.ts"
import { STEPS, fraction, nextOpen, remaining, shouldShow, stepState, type Step, type StepState } from "../onboarding.ts"
import { lastTest, onboard, progress, progressLoaded } from "../store.ts"
import { caption, noticeLine, small } from "./common.ts"
import { stepSpec, testSummary } from "./steps.ts"

const symbolFor = (s: StepState) => (s === "done" ? "checkmark.circle.fill" : s === "skipped" ? "arrow.uturn.right.circle" : s === "notNeeded" ? "minus.circle" : s === "current" ? "circle.inset.filled" : "circle")
const toneFor = (s: StepState) => (s === "done" ? "success" : s === "current" ? "accent" : "tertiary")

/** Signed out, or finished: what every layout shows instead of the steps. The
 *  layout is rebuilt only when this mode changes, not on every data reload. */
function gate(d: Core, layout: () => CmuxView): () => CmuxView | null {
  const mode = computed(() => {
    if (!progressLoaded()) return "loading"
    if (d.status()?.signed_in === false) return "signedOut"
    const p = progress()
    return p.finished || nextOpen(p, d.facts()) === null ? "done" : "steps"
  })
  return () => {
    switch (mode()) {
      case "loading":
        return caption(t("state.loading", "Loading…"))
      case "signedOut":
        return VStack({ spacing: 6 }, [
          EmptyState({ title: t("onboarding.signIn", "Sign in to cmux to set up CodeRouter"), message: t("onboarding.signIn.body", "CodeRouter acts as your cmux account and team."), symbol: "person.crop.circle" }),
          Button(t("action.signIn", "Sign In"), signIn)
        ])
      case "done":
        return VStack({ spacing: 6 }, [
          EmptyState({ title: t("onboarding.done", "CodeRouter is ready"), message: t("onboarding.done.body", "Your agents and keys fail over between your connected accounts."), symbol: "checkmark.seal" }),
          () => (lastTest()?.ok ? HStack([Spacer(), Icon("checkmark.circle.fill").color("success"), Text(testSummary(lastTest())).font("callout").monospaced().lineLimit(1).fixedSize("horizontal"), Spacer()]) : null),
          HStack({ spacing: 16 }, [Spacer(), small(t("action.openDashboard", "Open Dashboard"), () => openPane("dashboard")), small(t("action.reviewSetup", "Review Setup"), () => onboard({ type: "restart" }, d.facts())), Spacer()])
        ])
      default:
        return layout()
    }
  }
}

// MARK: Wizard

export function wizard(d: Core) {
  const current = computed(() => progress().current)
  return VStack({ spacing: 0 }, [
    gate(d, () => {
      const step = current()
      const spec = stepSpec(step, d)
      const index = STEPS.indexOf(step)
      return VStack({ spacing: 12 }, [
        HStack({ spacing: 6 }, [
          ...STEPS.map((s) => Circle({ fill: () => toneFor(stepState(s, progress(), d.facts())) }).frame({ width: 7, height: 7 })),
          Spacer(),
          Text(t("wizard.counter", "Step {n} of {total}", { n: index + 1, total: STEPS.length })).font("caption").color("tertiary")
        ]),
        VStack({ spacing: 4 }, [Text(spec.title).font("title2").weight("semibold"), caption(spec.sentence)]),
        spec.body(),
        noticeLine(),
        Spacer(),
        Divider(),
        HStack({ spacing: 10 }, [
          index > 0 ? small(t("action.back", "Back"), () => onboard({ type: "back" }, d.facts())) : null,
          small(t("action.skipSetup", "Skip Setup"), () => onboard({ type: "dismiss" }, d.facts())),
          Spacer(),
          small(t("action.skip", "Skip"), () => onboard({ type: "skip" }, d.facts())),
          Button(step === "test" ? t("action.finish", "Finish") : t("action.continue", "Continue"), () => onboard({ type: "next" }, d.facts()))
        ])
      ]).padding(16)
    })
  ])
}

// MARK: Checklist

export function checklist(d: Core) {
  const [open, setOpen] = signal<Step | null>(null)
  const expanded = () => open() ?? progress().current
  return VStack({ spacing: 0 }, [
    gate(d, () =>
      VStack({ spacing: 2 }, [
        HStack({ spacing: 6 }, [
          Text(t("checklist.title", "Set up CodeRouter")).font("caption").weight("semibold").color("secondary"),
          Spacer(),
          Text(() => t("checklist.left", "{n} left", { n: remaining(progress(), d.facts()) })).font("caption").color("tertiary"),
          small(t("action.hide", "Hide"), () => onboard({ type: "dismiss" }, d.facts()))
        ]),
        ProgressView(() => fraction(progress(), d.facts())).frame({ height: 4 }),
        ...STEPS.map((step) => checklistItem(d, step, expanded, setOpen))
      ])
    ),
    noticeLine()
  ])
}

function checklistItem(d: Core, step: Step, expanded: () => Step, setOpen: (s: Step | null) => void) {
  const spec = stepSpec(step, d)
  const state = computed(() => stepState(step, progress(), d.facts()))
  const isOpen = computed(() => expanded() === step)
  return VStack({ spacing: 2 }, [
    Row({ title: spec.title, subtitle: spec.summary, symbol: () => symbolFor(state()), tint: () => toneFor(state()), selected: isOpen }).onTap(() => setOpen(isOpen() ? null : step)),
    () =>
      isOpen() && state() !== "notNeeded"
        ? VStack({ spacing: 6 }, [
            caption(spec.sentence),
            spec.body(),
            HStack({ spacing: 10 }, [
              Spacer(),
              state() === "done" ? null : small(t("action.skip", "Skip"), () => (setOpen(null), onboard({ type: "skip" }, d.facts()))),
              small(t("action.done", "Done"), () => (setOpen(null), onboard({ type: "complete", step }, d.facts())))
            ])
          ]).padding({ top: 4, leading: 26, bottom: 8, trailing: 4 })
        : null
  ])
}

// MARK: Page

export function page(d: Core, inset = 16) {
  return VStack({ spacing: 0 }, [
    gate(d, () =>
      VStack({ spacing: 14 }, [
        HStack({ spacing: 8 }, [
          ProgressView(() => fraction(progress(), d.facts())),
          Text(() => t("checklist.left", "{n} left", { n: remaining(progress(), d.facts()) })).font("caption").color("tertiary"),
          small(t("action.skipSetup", "Skip Setup"), () => onboard({ type: "dismiss" }, d.facts()))
        ]),
        ...STEPS.map((step, i) => {
          const spec = stepSpec(step, d)
          const state = computed(() => stepState(step, progress(), d.facts()))
          return VStack({ spacing: 6 }, [
            HStack({ spacing: 8 }, [
              Icon(() => symbolFor(state())).color(() => toneFor(state())),
              Text(`${i + 1}. ${spec.title}`).font("headline"),
              Spacer(),
              Text(spec.summary).font("caption").color("secondary").lineLimit(1)
            ]),
            () => (state() === "notNeeded" ? null : VStack({ spacing: 6 }, [caption(spec.sentence), spec.body()]).padding({ top: 0, leading: 26, bottom: 0, trailing: 0 })),
            Divider()
          ])
        }),
        noticeLine()
      ]).padding(inset)
    )
  ])
}

/** Whether a surface should offer setup right now. */
export const setupPending = (d: Core) => shouldShow(progress(), d.facts()) && nextOpen(progress(), d.facts()) !== null
