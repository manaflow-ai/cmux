# ui-lab: render view code without building the app

`scripts/ui-lab/ui-lab.py` compiles a small harness plus the app source files
it names with plain `swiftc`, runs it, and writes PNGs. A compile takes a few
seconds and an unchanged re-run is cached, so a pixel question (spacing, glyph
weight, color in dark mode) gets an answer in seconds instead of an app build
or a CI UI-test run.

```bash
scripts/ui-lab/ui-lab.py scripts/ui-lab/harnesses/gpu-spinner.swift
scripts/ui-lab/ui-lab.py <harness> --watch   # re-render on every save
```

Each `UILab.render` call writes `<name>-light@2x.png`, `<name>-dark@2x.png`
and, with `detail:`, a 4x crop of that rect. Paths are printed; the default
directory is `$TMPDIR/cmux-ui-lab/<harness>`.

## Writing a harness

```swift
// ui-lab: source Sources/Sidebar/GPUSpinnerStyle.swift
// ui-lab: source Sources/Sidebar/GPUSpinnerNSView.swift
// ui-lab: shim SidebarAppearanceColorResolver

import AppKit

UILab.main {
    let bounds = NSRect(x: 0, y: 0, width: 200, height: 60)
    UILab.render(name: "example", detail: bounds) { scheme in
        let canvas = UILab.Canvas(frame: bounds)
        canvas.fill = .windowBackgroundColor
        // Build views with the app's real types and add them to canvas.
        return canvas
    }
}
```

`render` calls its closure once per color scheme, under that scheme's
appearance. Views that color themselves from a `colorScheme` property rather
than the appearance (`GPUSpinnerNSView` does) need it set from `scheme`, or
the dark render shows light colors.

- `source` lines are repo-relative app files. They compile as one module with
  the harness; `import Cmux*` lines are dropped.
- `shim` lines name files in `scripts/ui-lab/shims/`: small stand-ins for app
  types the sources use (for example `RenderableSystemSymbol`). Keep a shim
  faithful to the real type's behavior for what it renders.
- `UILab.Canvas` is flipped (top-down), like the sidebar cells. Mirror the
  real layout's metrics in the harness and cite where they come from.

A file that needs many app or package types does not fit. Split its drawing
into a file with only AppKit/SwiftUI dependencies, which also keeps it testable.

## What it is not

It renders a still frame of your view code in a mock layout, not the running
app: no window chrome, real cell layout, animation or live data. Confirm the
result in the app with a CI UI test (`scripts/ui-test`) or a dogfood tour
before calling a UI change done, and put that screenshot in the PR.

Compiling a few files is fine on a laptop; this is not an app build.
