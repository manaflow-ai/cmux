// Dots: the quietest sidebar. One line per workspace, a blue dot when it has unread items and a
// spinner while an agent works. Nothing else.
const BLUE = "#0A84FF"

sidebar(() =>
  LazyVStack({ spacing: 1 }, [
    ForEach({ items: () => data.workspaces() ?? [], key: (w) => w.id }, (w) =>
      HStack({ spacing: 8 }, [
        Circle().fill(() => (w().unread > 0 ? BLUE : "clear")).frame({ width: 7, height: 7 }),
        Text(() => w().title).lineLimit(1).truncation("tail").weight(() => (w().selected ? "semibold" : "regular")),
        Spacer(),
        () => (w().status === "working" ? ProgressView() : Spacer()),
      ])
        .paddingHorizontal(10).paddingVertical(5).cornerRadius(6)
        .background(() => (w().selected ? "selected" : "clear")).hoverBackground("hover")
        .onTap(() => cmux("workspace.select", { workspace_id: w().id })),
    ),
  ]),
)
