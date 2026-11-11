# Make a New Tab widget in five minutes

This folder is a complete cmux app that puts a clock on the New Tab page. Copy it, change the
render function, and you have your own widget, drawn in the page's widget row beside the built-in
ones, with the same type and inks.

Status: the page draws app widgets in the gallery (`newtab.app-widgets`) and against the web mock
today; in the app, once the Mac page bridge passes `cmux.newtab.widget/1` through as it does Session
Info's sections.

## 1. Copy the folder

Your own extensions live in one app, the customize folder (`~/.config/cmux/customize`, id
`local/customize`): it installs itself and reloads each time you save, keeping the last version
that worked. With no customize app yet, copy this one there:

```sh
test -d ~/.config/cmux/customize && cp -Rp ~/.config/cmux/customize ~/.config/cmux/customize.$(date +%Y%m%d-%H%M%S).bak
mkdir -p ~/.config/cmux/customize
cp -R examples/extensions/clock/. ~/.config/cmux/customize/
```

With one already, merge instead: add the `implements` entry below to its manifest and the render
function to its script.

## 2. Name it

In the copied `cmux-app.v2.json`, set `id` to `local/customize`, and change the widget's `title`
and `symbol`. `options.size` is `small` (a cell in the row, like the clock) or `wide` (the row's
whole width, for a list).

```json
"implements": {
  "cmux.newtab.widget/1": { "export": "renderClock", "title": "Clock", "symbol": "clock", "options": { "size": "small" } }
}
```

## 3. Draw it

`src/main.ts` exports the render function the manifest names. It returns a view, built from
signals: change a signal and only the nodes that read it are sent again.

```ts
export function renderClock() {
  const [now, setNow] = signal(Date.now())
  cmux.timer.every(1000, () => setNow(Date.now()))
  return Text(() => new Date(now()).toLocaleTimeString()).font("title2").monospaced()
}
```

A widget may use `VStack`, `HStack`, `Group`, `Text`, `Icon`, `Spacer`, `Divider`, `Badge`, `Row`,
`Button`, `ProgressView` and `EmptyState`, up to 64 nodes (`cmux.newtab.widget/1`). A widget that
draws past that stops and shows its name and why in its cell; the rest of the page is untouched.
`.onTap(() => ...)` runs with your app's own scopes, so ask for the scopes you use in `scopes`.

## 4. Build it

```sh
bun cmux-tui/crates/cmux-app-host/tools/pack.ts ~/.config/cmux/customize
```

This writes `dist/main.js`. Saving it is enough: the running app reloads.

## 5. Place it

Right-click the New Tab page, choose **Edit New Tab**, then **Add Widgets** and your widget. Drag it
along the row (or focus it and press Option-Left or Option-Right) to move it; its ✕ removes it. cmux
keeps the order for every New Tab page.

## What it costs

Nothing while nobody placed it: cmux lists your widget from its manifest and starts no script. Once
placed, it runs on each open New Tab page. A switch to another tab and back keeps the widget: the
page draws the same one and starts nothing again. When the page closes, cmux unmounts the widget,
and every timer the render function started stops with it (`cmux.timer.every` is floored at one
second). The page can be hidden while your widget is mounted, and cmux may pause a hidden page's
timers, so keep a tick cheap and do not rely on one while nobody looks. This clock sends one update
per tick that changes the time, and that update is one text node.

## Settings

`settings` in the manifest is a JSON schema; the values are in `cmux.app.settings()`. This clock has
`showSeconds` (off) and `hourCycle` (`system`, `12h` or `24h`).
