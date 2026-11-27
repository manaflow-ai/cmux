// Focus, redone: every New Tab is a title card. One question, what you are working on, set large
// and centered; under it one glass card with the session: a big clock that rolls its digits, a
// bar while it runs, three presets and a slider before it does, and the start button. Under the
// card, today's finished sessions as a row of marks. The rest of the window goes quiet through
// the profile's settings (a rail sidebar that hides its bands, the chat as messages, no hover
// cards, nothing moving). Only the kit: tones, not colors; fonts by name, not sizes.

const [task, setTask] = signal("")
const [minutes, setMinutes] = signal(25)
const [left, setLeft] = signal(null) // seconds left while a session runs
const [done, setDone] = signal(0)
const running = computed(() => left() !== null)
let tick = null

// Remembering needs storage:local (Settings > Apps > Focus); without it the page still works and
// forgets on reload.
const today = () => new Date().toISOString().slice(0, 10)
cmux.storage
  .get("focus")
  .then((saved) => {
    if (!saved) return
    setTask(saved.task || "")
    setDone(saved.day === today() ? saved.done || 0 : 0)
  })
  .catch(() => undefined)
const save = () => cmux.storage.set("focus", { task: task(), day: today(), done: done() }).catch(() => undefined)

const clock = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`
const run = (id, args) =>
  cmux.actions.run(id, args).catch((e) => cmux.toast({ title: "Turn on Run actions for Focus", message: String(e), tone: "warning" }))

function stop(finished) {
  if (tick !== null) cmux.timer.clear(tick)
  tick = null
  setLeft(null)
  if (finished) {
    setDone((n) => n + 1)
    save()
    cmux.toast({ title: "Session done", message: task() || "Take a short break.", tone: "success" })
  }
}

function start() {
  stop(false)
  save()
  setLeft(minutes() * 60)
  tick = cmux.timer.every(1000, () => {
    const next = (left() ?? 0) - 1
    if (next <= 0) stop(true)
    else setLeft(next)
  })
}

const PRESETS = [
  { minutes: 15, label: "Sprint" },
  { minutes: 25, label: "Pomodoro" },
  { minutes: 50, label: "Deep work" }
]

function preset(p) {
  return Button(
    VStack({ spacing: 1, alignment: "center" }, [
      Text(`${p.minutes} min`).font("callout").weight(() => (minutes() === p.minutes ? "semibold" : "regular")),
      Text(p.label).font("caption2").color(() => (minutes() === p.minutes ? cmux.theme.accent : cmux.theme.text.tertiary))
    ]).frame({ maxWidth: "infinity" }),
    () => setMinutes(p.minutes)
  ).frame({ maxWidth: "infinity" })
}

// Today's sessions: a filled mark for each one done, then empty ones up to a day of four.
function marks() {
  return HStack({ spacing: 6, alignment: "center" }, [
    Spacer(),
    () =>
      HStack(
        { spacing: 6 },
        Array.from({ length: Math.max(4, done()) }, (_, i) =>
          Circle()
            .fill(i < done() ? cmux.theme.accent : cmux.theme.separator)
            .frame({ width: 8, height: 8 })
            .transition("scale")
        )
      ),
    Text(() => (done() === 0 ? "No sessions yet today" : `${done()} ${done() === 1 ? "session" : "sessions"} today`))
      .font("caption")
      .color(cmux.theme.text.secondary),
    Spacer()
  ])
}

function renderFocus() {
  return VStack({ spacing: 22, alignment: "center" }, [
    Spacer(),
    VStack({ spacing: 6, alignment: "center" }, [
      Text(() => (running() ? "Working on" : "What are you working on?")).font("largeTitle").weight("semibold"),
      Text(() => (running() ? "" : "One thing. Name it, then start the clock."))
        .font("title3")
        .color(cmux.theme.text.secondary)
    ]),
    TextField(task, { placeholder: "Ship the onboarding flow", onEdit: setTask, onSubmit: () => (save(), start()) })
      .font("title2")
      .frame({ maxWidth: 520 }),
    Panel({ style: "glass", spacing: 14 }, [
      HStack([
        Spacer(),
        Text(() => clock(left() ?? minutes() * 60))
          .font("largeTitle")
          .weight("light")
          .monospaced()
          .contentTransition("numericText")
          .color(() => (running() ? cmux.theme.accent : cmux.theme.text.primary)),
        Spacer()
      ]),
      () =>
        running()
          ? ProgressView(() => 1 - (left() ?? 0) / (minutes() * 60))
          : VStack({ spacing: 10 }, [
              HStack({ spacing: 8 }, PRESETS.map(preset)),
              Slider(minutes, { min: 10, max: 90, step: 5, onChange: setMinutes })
            ]),
      Divider(),
      HStack({ spacing: 8 }, [
        () =>
          running()
            ? Button(HStack({ spacing: 4 }, [Icon("action.stop"), Text("Stop")]), () => stop(false))
            : Button(HStack({ spacing: 4 }, [Icon("media.play").color(cmux.theme.accent), Text("Start session").weight("semibold")]), start),
        Spacer(),
        Button(HStack({ spacing: 4 }, [Icon("agent.chat"), Text("Chat about it")]), () => run("palette.newAgentChat")),
        Button(HStack({ spacing: 4 }, [Icon("terminal"), Text("Terminal")]), () => run("newSurface"))
      ])
    ]).frame({ maxWidth: 520 }),
    marks(),
    Spacer()
  ]).padding()
}

globalThis.__cmuxAppExports = { renderFocus }
