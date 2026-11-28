// kitchen-sink: every runtime feature on one scrolling panel. Use it as a
// living demo and as a quick visual regression check for the JS lane.
//   cp Examples/CustomSidebars/kitchen-sink.js ~/.config/cmux/sidebars/
//   cmux right-sidebar set custom kitchen-sink    (or open it on the left)

const [count, setCount] = signal(0);
const [spun, setSpun] = signal(false);
const [echo, setEcho] = signal("");
const [rows, setRows] = signal([
  { id: "a", title: "Drag me" },
  { id: "b", title: "Reorder us" },
  { id: "c", title: "Locally" },
]);
const doubled = computed(() => count() * 2);

function section(title, children) {
  return VStack({ spacing: 6 }, [
    Text(title).font(10).weight("semibold").color("tertiary"),
    ...children,
  ])
    .paddingHorizontal(10).paddingVertical(8)
    .cornerRadius(10)
    .background("#7f7f7f14")
    .frame({ maxWidth: "infinity" });
}

sidebar(() =>
  VStack({ spacing: 8 }, [
    Text("Kitchen Sink").font(16).weight("semibold").paddingHorizontal(10),

    section("TYPOGRAPHY", [
      Text("headline").font("headline"),
      Text("13pt semibold").font(13).weight("semibold"),
      Text("italic serif-ish").font(12).italic(),
      Text("monospaced 11").font(11).monospaced(),
      Text("secondary").font(12).color("secondary"),
      Text("A very long line that truncates in the middle so both ends stay readable")
        .font(11).lineLimit(1).truncation("middle"),
    ]),

    section("SHAPES + COLORS", [
      HStack({ spacing: 8 }, [
        Circle({ size: 14 }).fill("accent"),
        Circle({ size: 14 }).fill("#E4573D"),
        Capsule({ width: 34, height: 14 }).fill("#34C759"),
        Rectangle({ width: 14, height: 14 }).fill("#FFD60A"),
        RoundedRectangle({ width: 22, height: 14, cornerRadius: 5 })
          .fill("#5E5CE6"),
        Circle({ size: 14 }).fill("#00000000").stroke("accent").strokeWidth(2),
        Spacer(),
      ]),
    ]),

    section("ICONS + ROTATION", [
      HStack({ spacing: 10 }, [
        Image("chevron.right")
          .font(12).weight("semibold")
          .rotation(() => (spun() ? 90 : 0)),
        Image("arrow.triangle.2.circlepath")
          .font(12)
          .rotation(() => (spun() ? 360 : 0)),
        Image("wand.and.stars").font(12).color("accent"),
        Spacer(),
        Text("tap to spin").font(10).color("tertiary"),
      ])
        .padding(4)
        .cornerRadius(6)
        .hoverBackground("#7f7f7f24")
        .onTap(() => setSpun(!spun())),
    ]),

    section("PROGRESS", [
      ProgressView({ value: () => ((count() % 10) / 10) }),
      Text(() => "count " + count() + " → doubled " + doubled()).font(11).color("secondary"),
      HStack({ spacing: 6 }, [
        Button("-", () => setCount(count() - 1)),
        Button("+", () => setCount(count() + 1)),
        Spacer(),
      ]),
    ]),

    section("HOVER + FADE + MARQUEE", [
      HStack({ spacing: 6 }, [
        Text("hover me: badge yields to X").font(11).lineLimit(1),
        Spacer(),
        ZStack({}, [
          Text("3").font("caption2").bold().color("white")
            .paddingHorizontal(5).paddingVertical(1)
            .background("#E4573D").cornerRadius(7)
            .hideOnHover(),
          Image("xmark").font(9).padding(3).cornerRadius(8)
            .hoverBackground("#7f7f7f4a")
            .showOnHover()
            .onTap(() => log("kitchen-sink close tapped")),
        ]),
      ])
        .paddingHorizontal(8).paddingVertical(5)
        .cornerRadius(7)
        .hoverBackground("#7f7f7f24"),
      HStack({ spacing: 0 }, [
        Text("An overflowing title that starts marqueeing after you hover it for half a second")
          .font(11).lineLimit(1).truncation("tail").marquee(),
        Spacer({ minLength: 0 }),
      ])
        .paddingHorizontal(8).paddingVertical(5)
        .cornerRadius(7)
        .hoverBackground("#7f7f7f24"),
      Text("constant trailing fade →").font(11).fade(46),
    ]),

    section("TEXT FIELD (live)", [
      TextField("", {
        placeholder: "Type, echoes live below",
        autofocus: false,
        onEdit: (t) => setEcho(t ?? ""),
        onSubmit: (t) => setEcho((t ?? "") + " ⏎"),
      }),
      Text(() => (echo() ? "» " + echo() : "» (empty)")).font(11).monospaced().color("secondary"),
    ]),

    section("MENUS", [
      Text("right-click me").font(11)
        .paddingHorizontal(8).paddingVertical(5)
        .cornerRadius(7).hoverBackground("#7f7f7f24")
        .contextMenu([
          Button("Log hello", () => log("hello from kitchen-sink")),
          Menu("Submenu", [
            Button("Open cmux repo", () => openURL("https://github.com/manaflow-ai/cmux")),
          ]),
          Divider(),
          Button("Destructive", () => log("boom")).destructive(),
        ]),
    ]),

    section("ZSTACK ALIGNMENT", [
      ZStack({ alignment: "bottomTrailing" }, [
        Rectangle({ width: 90, height: 34 }).fill("#7f7f7f24"),
        Circle({ size: 10 }).fill("accent"),
      ]),
    ]),

    section("REORDERABLE (local)", [
      Reorderable(
        {
          items: rows,
          key: (r) => r.id,
          onMove: (id, index) => {
            const list = rows().filter((r) => r.id !== id);
            const me = rows().find((r) => r.id === id);
            list.splice(index, 0, me);
            setRows(list);
          },
        },
        (r) =>
          HStack({ spacing: 6 }, [
            Image("line.3.horizontal").font(9).color("tertiary"),
            Text(() => r().title).font(11),
            Spacer(),
          ])
            .paddingHorizontal(8).paddingVertical(4)
            .cornerRadius(6)
            .hoverBackground("#7f7f7f24")
            .frame({ maxWidth: "infinity" })
      ),
    ]),

    section("LIVE DATA", [
      Text(() => "clock " + (data.clock()?.time ?? "—")).font(11).monospaced(),
      Text(() => (data.workspaceCount() ?? 0) + " workspaces, " + (data.unreadTotal() ?? 0) + " unread")
        .font(11).color("secondary"),
      Text(() => "selected: " + (data.selectedTitle() || "—"))
        .font(11).lineLimit(1).truncation("tail").color("secondary"),
    ]),
    Spacer(),
  ]).paddingHorizontal(6),
  { surface: "glass" }
)
