import { BigNumber, bySize, Caption, Label, RowList, SPACE, Spacer, VStack, widget, WidgetFrame, WidgetSymbol, WidgetTitle } from "cmux-extension-sdk"

type Build = { id: string; result: "passed" | "failed"; ago: string }

const BUILDS: Build[] = [
  { id: "#412", result: "failed", ago: "12 min ago" },
  { id: "#411", result: "passed", ago: "1 h ago" },
  { id: "#410", result: "passed", ago: "3 h ago" },
]

const FAILING_TESTS = 3

export const renderWidget = widget((ctx) => {
  const last = BUILDS[0]!
  const passed = last.result === "passed"

  return WidgetFrame(
    [
      WidgetTitle("CI · main", { symbol: "hammer", tint: "secondary" }),
      bySize(ctx, {
        small: () =>
          VStack({ spacing: SPACE.xxs, alignment: "leading" }, [
            Spacer(),
            WidgetSymbol(passed ? "checkmark.circle.fill" : "xmark.circle.fill", {
              tint: passed ? "success" : "danger",
            }),
            BigNumber(passed ? "Passed" : "Failed", { role: "heading" }),
            Caption(passed ? last.ago : `${FAILING_TESTS} tests failing · ${last.ago}`),
          ]),
        medium: () =>
          VStack({ spacing: SPACE.s, alignment: "leading" }, [
            Label("Last three builds"),
            RowList(
              () =>
                BUILDS.map((b) => ({
                  id: b.id,
                  title: `${b.id} ${b.result === "passed" ? "passed" : "failed"}`,
                  detail: b.ago,
                  symbol: b.result === "passed" ? "checkmark.circle.fill" : "xmark.circle.fill",
                  tint: b.result === "passed" ? "success" : "danger",
                })),
              { max: 3 }
            ),
          ]),
      }),
    ],
    { place: ctx.place }
  )
})
