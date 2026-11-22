# Native sidebar geometry adapter

`geometry-sidebar-cli.ts` consumes the native gallery export without claiming
accessibility or glyph measurements. It maps the recorded flipped list coordinates
through `listInImage` and `backingScale` to screenshot pixels. A mark is a measured
center point with zero area; no icon bounds are invented. PNG dimensions, content
hashes, geometry hash and exact source revision accompany each converted artifact.

The declarative fixture contract covers both densities, all four hover states and
all 15 fixture rows. Additional rows are checked too. Every mark and end-slot close
control shares the declared column within 0.5 points; each mark/control is centered
in its own row. Hover controls exclude dot/status/unreadDot marks, while a structural
chevron may remain. The captured loading header requires its chevron and more control.

Run on a fleet test worker after downloading and verifying the capture archive:

```sh
bun scripts/gallery-matrix/geometry-sidebar-cli.ts \
  --artifact-dir /path/to/sidebar-trailing-column-gallery \
  --output-dir /path/to/converted-sidebar \
  --expected-sha 66f9626ce9446b70d1c5de36feeba427946e13de \
  --geometry-sha256 e3630aefed21defc15a20688e72ac87419e12e63d944df1b61e74341b176ea11
```

Capture `6f3f006e357248af969c0fd0` has archive SHA-256
`37e5ced54c3aec79e7bacba0a67897fb30281b8e0d75ca9babbcf4bcb6b2d79e`.
The recorded test fixture retains its eight full row inventories and PNG hashes.
Before capture `0aeb3d7d37f5c3f5873d5da1` has archive SHA-256
`dc6b0230e5437473022ae2244672b1fde3d45180610590794b1d824f7cbf94af`.
Its exporter lacked mapping. Unit tests replay only its measured mark differences
using the owner's identical-harness attestation, independently matching all PNG
sizes and row-frame sequences. Production conversion rejects missing mapping.

Coverage gaps remain explicit: this export is view-frame evidence, not AX or ink;
it does not record theme identity, so it cannot establish light/dark coverage.
Producing fresh native captures remains the native gallery runner's
responsibility; this adapter does not schedule builds. Like the rest of the
geometry audit, the adapter regressions are lane-run rather than a CI gate; run
them through the fleet from the repository root:

```sh
cmux-ci test --setup webviews --timeout 600 -- bash -c \
  'cd scripts/gallery-matrix && bun install --frozen-lockfile && bun test geometry-sidebar.test.ts'
```
