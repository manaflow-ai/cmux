// A tiny focus timer: native controls, a real timer, and a toast when it ends.
function renderTimer() {
  const [seconds, setSeconds] = signal(25 * 60)
  const [running, setRunning] = signal(false)
  const workspaces = cmux.live("workspace.list", {})
  const current = computed(() => (workspaces() || []).find((workspace) => workspace.focused))
  let timer = null
  const stopTimer = () => {
    if (timer) {
      cmux.timer.clear(timer)
      timer = null
    }
  }
  const tick = () => {
    if (!running()) return
    if (seconds() <= 1) {
      setSeconds(0)
      setRunning(false)
      stopTimer()
      cmux.toast({ title: "Focus complete", tone: "success" })
      return
    }
    setSeconds((n) => n - 1)
  }
  const toggle = () => {
    if (running()) {
      setRunning(false)
      stopTimer()
    } else {
      setRunning(true)
      if (!timer) timer = cmux.timer.every(1000, tick)
    }
  }
  const reset = () => {
    setRunning(false)
    stopTimer()
    setSeconds(25 * 60)
  }
  const clock = () => `${String(Math.floor(seconds() / 60)).padStart(2, "0")}:${String(seconds() % 60).padStart(2, "0")}`
  onCleanup(stopTimer)
  return Panel({ title: "Focus" }, [
    Text(() => current()?.name || "Current workspace").font("caption"),
    Text(() => clock()).font("title"),
    HStack([Button(() => running() ? "Pause" : "Start", toggle), Button("Reset", reset)])
  ])
}
globalThis.__cmuxAppExports = { renderTimer }
