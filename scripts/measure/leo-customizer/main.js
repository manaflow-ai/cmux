// Leo's Customizer: a bottom-left sidebar section of grouped, one-click customizations.
// Classic script (no import/export). Scene globals and `cmux` are provided by the host.
//
// What a click can do: an app cannot write global settings (settings.set is never offered to
// apps), so a row either runs a cmux action that changes the setting (sidebar density,
// animations, compact list, vertical tabs, ...) or opens Settings at that exact setting.
// Every row shows the current value, read with settings.get.

const APP_ID = "local/leo-customizer"

const THEME_FILES = ["harbor", "moss", "meadow", "lily-pond", "phosphor", "charcoal", "claude-desktop", "classic-desktop"]

// Real keys from schemas/settings/settings-schema.json, read for display.
const KEYS = [
  "appearance.themeFile",
  "appearance.accent",
  "app.uiScale",
  "ui.animations.enabled",
  "ui.calm",
  "sidebar.density",
  "sidebar.textSize",
  "sidebar.controlsOnHover",
  "sidebar.showSpaces",
  "sidebar.minimal",
  "sidebar.showTimestamps",
  "sidebar.detailedStatusIcons",
  "sidebar.hoverCards.enabled",
  "sidebar.sectionLook",
  "tabs.verticalTabs",
  "agentPane.display.font.size",
  "agentPane.display.code.scale",
  "agentPane.display.font.preset",
  "agentPane.display.fullWidth",
  "agentPane.display.pinnedPlan",
  "agentPane.display.finishSound",
  "agentPane.display.promptCoach",
  "experiments.composerV2"
]

// settings.get answers { key, value, ... }; tolerate a bare value too.
const unwrap = (r) => (r && typeof r === "object" && !Array.isArray(r) && "value" in r ? r.value : r)

const show = (v) => {
  if (v === undefined || v === null || v === "") return "default"
  if (v === true) return "On"
  if (v === false) return "Off"
  return String(v)
}

const errText = (e) => (e && e.message ? e.message : String(e))

function renderCustomizer() {
  const [vals, setVals] = signal({})
  const [readError, setReadError] = signal(null)

  const load = async () => {
    const next = {}
    let failed = null
    await Promise.all(
      KEYS.map(async (key) => {
        try {
          next[key] = unwrap(await cmux.settings.get({ key }))
        } catch (e) {
          failed = failed || errText(e)
        }
      })
    )
    setVals(next)
    setReadError(Object.keys(next).length === 0 ? failed : null)
  }
  const refreshSoon = () => {
    cmux.timer.after(400, load)
    cmux.timer.after(1500, load)
  }
  load()
  cmux.timer.every(30000, load)

  const v = (key) => vals()[key]
  const on = (key) => v(key) === true

  const run = async (id, args, done) => {
    try {
      await cmux.actions.run(id, args || {})
      if (done) cmux.toast({ title: done, tone: "success" })
      refreshSoon()
    } catch (e) {
      cmux.toast({ title: `Could not run ${id}`, message: errText(e), tone: "danger" })
    }
  }

  const openAt = (setting, section) => run("openSettings", { section: section || setting.split(".")[0], setting })

  // Settings sections are general, appearance, terminal, browser, ...; chat display lives in appearance.
  const sectionOf = (key) => (key.startsWith("appearance.") || key.startsWith("ui.") || key.startsWith("app.") || key.startsWith("agentPane.") || key.startsWith("sidebar.") || key.startsWith("tabs.") ? "appearance" : key.startsWith("experiments.") ? "development" : "general")

  const deepRow = (title, key, symbol) =>
    Row({ title, subtitle: () => show(v(key)), symbol, accessory: "chevron.right" })
      .help(`Opens Settings at ${key}`)
      .onTap(() => openAt(key, sectionOf(key)))

  // ---- Look ----
  const themeMenu = Menu(
    "Theme file…",
    THEME_FILES.map((name) =>
      Button(
        () => (String(v("appearance.themeFile") || "").includes(name) ? `✓ ${name}` : name),
        () => run("customize.open", { draft: `Set my theme file (appearance.themeFile) to ${name}.` })
      )
    )
  )

  const look = Panel({ title: "Look" }, [
    Row({
      title: "Theme file",
      subtitle: () => show(v("appearance.themeFile")),
      symbol: "paintpalette",
      tint: "accent",
      accessory: "chevron.right"
    })
      .help("Opens Settings at the theme file. The menu below asks an agent to switch it for you.")
      .onTap(() => openAt("appearance.themeFile", "appearance")),
    themeMenu,
    deepRow("Accent", "appearance.accent", "drop"),
    Row({ title: "Change background…", symbol: "photo" }).onTap(() => run("appearance.changeBackground")),
    HStack([
      Text(() => `Interface size ${show(v("app.uiScale"))}`).secondary(),
      Spacer(),
      Button("−", () => run("appearance.interfaceSize.decrease")),
      Button("Reset", () => run("appearance.interfaceSize.reset")),
      Button("+", () => run("appearance.interfaceSize.increase"))
    ]),
    Row({
      title: "Animations",
      symbol: "sparkles",
      badge: () => show(v("ui.animations.enabled")),
      tint: () => (v("ui.animations.enabled") === false ? "secondary" : "accent")
    }).onTap(() => run("appearance.animations.toggle"))
  ])

  // ---- Sidebar ----
  const densityRow = (level, symbol) =>
    Row({
      title: level[0].toUpperCase() + level.slice(1),
      symbol,
      selected: () => (v("sidebar.density") || "compact") === level,
      accessory: () => ((v("sidebar.density") || "compact") === level ? "checkmark" : null),
      tint: () => ((v("sidebar.density") || "compact") === level ? "accent" : null)
    }).onTap(() => run(`sidebar.density.${level}`))

  const sidebar = Panel({ title: "Sidebar" }, [
    densityRow("compact", "rectangle.compress.vertical"),
    densityRow("comfortable", "rectangle"),
    densityRow("expanded", "rectangle.expand.vertical"),
    Divider(),
    Row({ title: "Compact workspace list", symbol: "list.bullet" }).onTap(() => run("sidebar.compactList.toggle")),
    Row({
      title: "Controls only on hover",
      symbol: "cursorarrow.rays",
      badge: () => show(v("sidebar.controlsOnHover"))
    }).onTap(() => run(on("sidebar.controlsOnHover") ? "sidebar.controlsOnHover.off" : "sidebar.controlsOnHover.on")),
    Row({
      title: "Spaces",
      symbol: "square.stack",
      badge: () => show(v("sidebar.showSpaces"))
    }).onTap(() => run(v("sidebar.showSpaces") === false ? "sidebar.spaces.show" : "sidebar.spaces.hide")),
    deepRow("Sidebar text size", "sidebar.textSize", "textformat.size"),
    deepRow("Section look", "sidebar.sectionLook", "square.split.1x2"),
    Row({ title: "Customize sidebar…", symbol: "slider.horizontal.3", accessory: "chevron.right" }).onTap(() => run("sidebar.customize"))
  ])

  // ---- Chat ----
  const chat = Panel({ title: "Chat" }, [
    Row({ title: "Chat display…", symbol: "text.bubble", accessory: "chevron.right" })
      .help("Toggles the chat's display settings panel (font, sizes, width)")
      .onTap(() => run("agentPane.toggleDisplaySettings")),
    deepRow("Chat text size", "agentPane.display.font.size", "textformat.size"),
    deepRow("Code size", "agentPane.display.code.scale", "chevron.left.forwardslash.chevron.right"),
    deepRow("Chat font", "agentPane.display.font.preset", "textformat")
  ])

  // ---- Quick toggles ----
  // `action` set: the click flips it directly; otherwise it opens Settings at the key.
  const TOGGLES = [
    { title: "Vertical tabs", key: "tabs.verticalTabs", symbol: "sidebar.squares.left", action: "tabs.verticalTabs.toggle" },
    { title: "Full-width chat", key: "agentPane.display.fullWidth", symbol: "arrow.left.and.right" },
    { title: "Pinned plan", key: "agentPane.display.pinnedPlan", symbol: "pin" },
    { title: "Finish sound", key: "agentPane.display.finishSound", symbol: "speaker.wave.2" },
    { title: "Prompt coach", key: "agentPane.display.promptCoach", symbol: "lightbulb" },
    { title: "Sidebar timestamps", key: "sidebar.showTimestamps", symbol: "clock" },
    { title: "Detailed status icons", key: "sidebar.detailedStatusIcons", symbol: "circle.grid.2x2" },
    { title: "Minimal sidebar", key: "sidebar.minimal", symbol: "minus.rectangle" },
    { title: "Hover cards", key: "sidebar.hoverCards.enabled", symbol: "rectangle.on.rectangle" },
    { title: "Composer v2", key: "experiments.composerV2", symbol: "flask" }
  ]
  const toggles = Panel(
    { title: "Quick toggles" },
    TOGGLES.map((t) =>
      Row({
        title: t.title,
        symbol: t.symbol,
        badge: () => show(v(t.key)),
        tint: () => (on(t.key) ? "success" : "secondary"),
        accessory: t.action ? null : "chevron.right"
      })
        .help(t.action ? `Flips ${t.key}` : `Opens Settings at ${t.key}`)
        .onTap(() => (t.action ? run(t.action) : openAt(t.key, sectionOf(t.key))))
    )
  )

  // ---- Actions ----
  const ELEMENTS = ["sidebar", "sidebarSection", "workspaceRow", "titlebar", "tabBar", "tab", "pane", "chatComposer", "chatMessages", "widget"]
  const actions = Panel({ title: "Actions" }, [
    Row({ title: "Open Settings", symbol: "gearshape" }).onTap(() => run("openSettings", { section: "appearance" })),
    Row({ title: "Customize with an agent…", subtitle: "Starts a /customize chat", symbol: "wand.and.stars" }).onTap(() => run("customize.open", {})),
    Menu(
      "Customize one element…",
      ELEMENTS.map((element) => Button(element, () => run("customize.open", { element })))
    ),
    Menu(
      "Roll back a customization…",
      ELEMENTS.map((element) => Button(element, () => run("customize.reset", { element }, `Reset ${element}`)))
    ),
    Row({ title: "Reload custom views", symbol: "arrow.clockwise" }).onTap(() => run("app.reloadCustomViews", {}, "Reloaded")),
    Row({ title: "Refresh values", symbol: "arrow.triangle.2.circlepath" }).onTap(load),
    Row({ title: "Hide this panel", subtitle: "Show it again: palette › Show Hidden App…", symbol: "eye.slash", tint: "tertiary" }).onTap(() =>
      run("app.hide", { app: APP_ID })
    )
  ])

  return VStack([
    () => (readError() ? EmptyState({ title: "Cannot read settings", message: `${readError()} (turn on Settings > Apps > Leo's Customizer > settings:read)`, symbol: "exclamationmark.triangle" }) : null),
    look,
    sidebar,
    chat,
    toggles,
    actions
  ])
}

globalThis.__cmuxAppExports = { renderCustomizer }
