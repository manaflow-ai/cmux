// Focus: every New Tab is one question, what you are working on, and a timed session. The rest of
// the window goes quiet through the profile's settings (a rail sidebar that hides its bands, the
// chat as messages, no hover cards, nothing moving).

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

function renderFocus() {
  return VStack({ spacing: 16 }, [
    Spacer(),
    Text("What are you working on?").font("largeTitle").weight("semibold"),
    TextField(task, { placeholder: "One thing", onEdit: setTask, onSubmit: () => (save(), start()) }).font("title2"),
    Panel({ style: "card" }, [
      Text(() => clock(left() ?? minutes() * 60)).font("largeTitle").monospaced(),
      () => (running() ? ProgressView(() => 1 - (left() ?? 0) / (minutes() * 60)) : Slider(minutes, { min: 10, max: 90, step: 5, onChange: setMinutes })),
      HStack({ spacing: 8 }, [
        () => (running() ? Button("Stop", () => stop(false)) : Button("Start session", start)),
        Button("Chat about it", () => run("palette.newAgentChat")),
        Button("Terminal", () => run("newSurface")),
        Spacer(),
        Text(() => `${done()} today`).font("caption").color(cmux.theme.text.secondary)
      ])
    ]),
    Spacer()
  ])
}

globalThis.__cmuxAppExports = { renderFocus }
