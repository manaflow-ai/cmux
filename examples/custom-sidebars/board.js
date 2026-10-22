// Board: workspaces grouped by what they need from you. "Needs you" first, then "Working", then
// the rest. Each group is its own keyed list, so a row that changes group moves, nothing rebuilds.
const GROUPS = [
  { title: "NEEDS YOU", status: "needs-attention", tone: "warning" },
  { title: "WORKING", status: "working", tone: "success" },
  { title: "IDLE", status: "idle", tone: "tertiary" },
]

function row(w) {
  return HStack({ spacing: 8 }, [
    Text(() => w().title).lineLimit(1).truncation("tail"),
    Spacer(),
    () => (w().unread > 0 ? Badge(() => String(w().unread), "accent") : Spacer()),
  ])
    .paddingHorizontal(10).paddingVertical(5).cornerRadius(6)
    .background(() => (w().selected ? "selected" : "clear")).hoverBackground("hover")
    .onTap(() => cmux("workspace.select", { workspace_id: w().id }))
}

sidebar(() => {
  const all = computed(() => data.workspaces() ?? [])
  return LazyVStack({ spacing: 2 }, GROUPS.map((group) => {
    const rows = computed(() => all().filter((w) => w.status === group.status))
    return VStack({ spacing: 1 }, [
      Text(() => `${group.title} · ${rows().length}`).font(10).weight("semibold").color(group.tone)
        .paddingHorizontal(10).paddingVertical(4),
      ForEach({ items: rows, key: (w) => w.id }, row),
    ])
  }))
})
