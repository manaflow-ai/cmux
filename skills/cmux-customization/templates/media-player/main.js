// A radio player in the sidebar: SomaFM's listener-supported stations (no key, no account),
// the song on now, and play, previous, next and favorites. Play opens the station's stream in
// one cmux browser tab, so the tab's speaker button mutes it and closing the tab stops it; a
// station change moves that tab, never a second stream. The stations, their songs and whether
// the stream tab is open are read every 30 s while the section shows. Needs net:somafm.com
// (the stations), actions:run (play), browser:write (switch stations) and storage:local (your
// station and favorites), in Settings > Apps > My views.

const [stations, setStations] = signal([]) // [{ id, title, genre, description, listeners, song }]
const [current, setCurrent] = signal(null) // the chosen station's id
const [favorites, setFavorites] = signal([]) // station ids
const [onlyFavorites, setOnlyFavorites] = signal(false)
const [playing, setPlaying] = signal(false)
const [error, setError] = signal(null)
let loaded = false

const message = (e) => (e instanceof Error ? e.message : String(e))

async function loadStations() {
  try {
    const r = await cmux.net.fetch("https://somafm.com/channels.json")
    if (!r.ok) throw new Error(`SomaFM answered ${r.status}`)
    setStations(
      (r.json().channels || []).map((c) => ({
        id: c.id,
        title: c.title,
        genre: String(c.genre || "").split("|").join(", "),
        description: c.description || "",
        listeners: Number(c.listeners) || 0,
        song: c.lastPlaying || ""
      }))
    )
    setError(null)
  } catch (e) {
    setError(message(e))
  }
}

const isFavorite = (id) => favorites().includes(id)
// Favorites first, then the stations most people listen to.
const shown = computed(() => {
  const all = [...stations()].sort((a, b) => Number(isFavorite(b.id)) - Number(isFavorite(a.id)) || b.listeners - a.listeners)
  return onlyFavorites() ? all.filter((s) => isFavorite(s.id)) : all
})
const station = computed(() => stations().find((s) => s.id === current()) ?? shown()[0] ?? null)

// SomaFM writes the song as "Artist - Title"; the first " - " splits it.
function split(song) {
  const at = song.indexOf(" - ")
  return at < 0 ? { artist: "", title: song } : { artist: song.slice(0, at), title: song.slice(at + 3) }
}

const keep = (key, value) => cmux.storage.set(key, value).catch(() => undefined)

function choose(s) {
  setCurrent(s.id)
  keep("station", s.id)
}

const STREAM = "https://ice2.somafm.com/"
const streamOf = (s) => `${STREAM}${s.id}-128-mp3`

// The player's own tab: the browser tab on a SomaFM stream, if one is open. Reading it
// (browser:read, granted at install) says whether the radio plays: closing the tab stops it.
let streamBrowser = null // its browser id, from the last read
async function readPlaying() {
  try {
    streamBrowser = (await cmux.browser.list({})).find((b) => b.url.startsWith(STREAM))?.id ?? null
  } catch (e) {
    streamBrowser = null
  }
  setPlaying(streamBrowser !== null)
}

// One stream at a time: a station change moves the open stream tab to the new station
// (browser:write), and only with no stream tab open does play open one (actions:run). Both
// calls go out in the click's own turn: an action from a click must not wait on a read first.
function play(s) {
  if (!s) return
  choose(s)
  const moving = streamBrowser !== null
  const call = moving ? cmux.browser.navigate({ browser: streamBrowser, url: streamOf(s) }) : cmux.actions.run("openBrowser", { url: streamOf(s) })
  call.then(readPlaying, async (e) => {
    await readPlaying()
    // A stream tab closed since the last read: the next Play opens a new one. Otherwise the
    // call was refused, most often for a scope that is off.
    const title =
      moving && streamBrowser === null
        ? "Press Play again to open the radio tab"
        : `Turn on ${moving ? "Change browsers" : "Run actions"} for My views to play`
    cmux.toast({ title, message: message(e), tone: "warning" })
  })
}

// Previous and next walk the list as it shows, and play when the player was playing.
function step(by) {
  const list = shown()
  if (list.length === 0) return
  const at = list.findIndex((s) => s.id === station()?.id)
  const next = list[(at + by + list.length) % list.length]
  playing() ? play(next) : choose(next)
}

function toggleFavorite(id) {
  const next = isFavorite(id) ? favorites().filter((f) => f !== id) : [...favorites(), id]
  setFavorites(next)
  keep("favorites", next)
}

// Timers belong to the view that started them and end with it, so every render starts its own;
// the saved station and favorites are read once.
function start() {
  cmux.timer.every(30000, () => (loadStations(), readPlaying()))
  loadStations()
  readPlaying()
  if (loaded) return
  loaded = true
  cmux.storage.get("station").then((id) => typeof id === "string" && current() === null && setCurrent(id), () => undefined)
  cmux.storage.get("favorites").then((ids) => Array.isArray(ids) && setFavorites(ids), () => undefined)
}

function renderPlayer() {
  start()
  return VStack({ spacing: 6 }, [
    Panel({ title: "Now playing" }, [
      () => {
        const s = station()
        if (!s) return stations().length === 0 && !error() ? ProgressView() : null
        const song = split(s.song)
        return VStack({ spacing: 2 }, [
          Text(song.title || s.title).font("headline").lineLimit(1),
          Text(song.artist || s.description).color(cmux.theme.text.secondary).lineLimit(1),
          HStack({ spacing: 4 }, [
            Icon(playing() ? "dot.radiowaves.left.and.right" : "radio").color(playing() ? cmux.theme.accent : cmux.theme.text.tertiary),
            Text(`${s.title} · ${s.listeners} listening`).font("caption").color(cmux.theme.text.tertiary).lineLimit(1)
          ])
        ])
      },
      HStack({ spacing: 8 }, [
        Button(Icon("backward.fill"), () => step(-1)).help("Previous station"),
        Button(HStack({ spacing: 4 }, [Icon("play.fill"), Text("Play")]), () => play(station())),
        Button(Icon("forward.fill"), () => step(1)).help("Next station"),
        Spacer(),
        Button(Icon(() => (station() && isFavorite(station().id) ? "star.fill" : "star")), () => station() && toggleFavorite(station().id)).help("Favorite")
      ])
    ]),
    Toggle(onlyFavorites, { label: "Favorites only", onChange: setOnlyFavorites }),
    ForEach({ items: shown, key: (s) => s.id }, (s) =>
      Row({
        title: () => s().title,
        subtitle: () => s().song || s().genre,
        symbol: () => (s().id === station()?.id ? (playing() ? "speaker.wave.2.fill" : "radio.fill") : isFavorite(s().id) ? "star.fill" : "radio"),
        tint: () => (s().id === station()?.id ? cmux.theme.accent : isFavorite(s().id) ? cmux.theme.warning : cmux.theme.text.secondary)
      })
        .help(() => `${s().genre} · ${s().description}`)
        .onTap(() => play(s()))
        .contextMenu(() => [Button("Play", () => play(s())), Button(isFavorite(s().id) ? "Remove from favorites" : "Add to favorites", () => toggleFavorite(s().id))])
    ),
    () => (onlyFavorites() && shown().length === 0 ? EmptyState({ title: "No favorites yet", symbol: "star" }) : null),
    () => (error() ? Text(error()).font("caption").color(cmux.theme.warning) : null)
  ])
}

globalThis.__cmuxAppExports = { renderPlayer }
