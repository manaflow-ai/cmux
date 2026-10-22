// Cards: one small card per workspace with its agents. The card's edge shows the state: amber
// when an agent waits for you, green while one works.
const EDGE = { "needs-attention": "#FF9F0A", working: "#30D158", idle: "#7f7f7f40" }

sidebar(() =>
  LazyVStack({ spacing: 6 }, [
    ForEach({ items: () => data.workspaces() ?? [], key: (w) => w.id }, (w) =>
      HStack({ spacing: 8 }, [
        Rectangle().fill(() => EDGE[w().status] ?? EDGE.idle).frame({ width: 3 }),
        VStack({ spacing: 2, alignment: "leading" }, [
          HStack({ spacing: 6 }, [
            Text(() => w().title).weight("semibold").lineLimit(1).truncation("tail"),
            Spacer(),
            () => (w().unread > 0 ? Badge(() => String(w().unread), "accent") : Spacer()),
          ]),
          Text(() => {
            const agents = w().agents ?? []
            if (agents.length === 0) return "no agents"
            const waiting = agents.filter((a) => a.status === "needs_input").length
            return waiting > 0 ? `${waiting} of ${agents.length} agents wait for you` : `${agents.length} agents`
          }).font("caption").color("secondary").lineLimit(1),
        ]),
      ])
        .padding(8).cornerRadius(8).background(() => (w().selected ? "selected" : "#7f7f7f18")).hoverBackground("hover")
        .onTap(() => cmux("workspace.select", { workspace_id: w().id })),
    ),
  ]).paddingHorizontal(8),
)
