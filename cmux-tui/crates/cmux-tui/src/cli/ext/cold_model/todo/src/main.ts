import { BigNumber, bySize, Caption, Label, RowList, SPACE, Spacer, VStack, widget, WidgetEmpty, WidgetFrame, WidgetTitle } from "cmux-extension-sdk"

type Task = { id: string; title: string; due: string; done: boolean; overdue?: boolean }

const TASKS: Task[] = [
  { id: "1", title: "Reply to Maya", due: "09:00", done: true },
  { id: "2", title: "Send the invoice", due: "09:30", done: false, overdue: true },
  { id: "3", title: "Review the PR", due: "10:00", done: true },
  { id: "4", title: "Book the dentist", due: "11:00", done: true },
  { id: "5", title: "Write the notes", due: "14:30", done: false },
  { id: "6", title: "Plan the sprint", due: "15:00", done: false },
  { id: "7", title: "Call the bank", due: "16:00", done: false },
  { id: "8", title: "Ship the release", due: "17:00", done: false },
]

export const renderWidget = widget((ctx) => {
  const open = TASKS.filter((t) => !t.done).sort((a, b) => a.due.localeCompare(b.due))
  const next = open.slice(0, 3)
  const overdueCount = open.filter((t) => t.overdue).length

  if (open.length === 0) {
    return WidgetFrame([WidgetEmpty("All done", { message: "Nothing left today", symbol: "checkmark.circle" })], { place: ctx.place })
  }

  return WidgetFrame(
    [
      WidgetTitle("Today", { symbol: "checklist" }),
      bySize(ctx, {
        small: () =>
          VStack({ spacing: SPACE.xxs, alignment: "leading" }, [
            Spacer(),
            BigNumber(String(open.length)),
            Caption(`left of ${TASKS.length}${overdueCount > 0 ? ` · ${overdueCount} overdue` : ""}`),
          ]),
        medium: () =>
          VStack({ spacing: SPACE.s, alignment: "leading" }, [
            Label(`${open.length} left of ${TASKS.length}`),
            RowList(
              () =>
                next.map((t) => ({
                  id: t.id,
                  title: t.title,
                  detail: t.overdue ? "Overdue" : undefined,
                  trailing: t.due,
                  tint: t.overdue ? "danger" : undefined,
                  symbol: t.overdue ? "exclamationmark.circle" : undefined,
                })),
              { max: 3 }
            ),
          ]),
      }),
    ],
    { place: ctx.place }
  )
})
