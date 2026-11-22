// The three designs of the Finder pane (DEV/NIGHTLY setting `variant`):
//   listPreview - path bar, sortable list with columns, preview on the right, jobs below
//   columns     - column view: each folder opens a column to the right, preview in the last
//   dualPane    - two lists side by side (for example this Mac and a remote host) with copy and move between them

import { transfer } from "../actions.ts"
import { type Browser, createBrowser } from "../browser.ts"
import { t } from "../l10n.ts"
import { type Entry, kindGroup } from "../model/entries.ts"
import { join, type Location } from "../model/handles.ts"
import { createPreview } from "../preview.ts"
import { conns, request, roots } from "../store.ts"
import { entryRow, listHeader, listState, pager, noticeRow, pathBar, statusLine } from "./common.ts"
import { jobsStrip } from "./jobs.ts"
import { previewPane } from "./preview.ts"
import { newFolderRow, toolbar } from "./toolbar.ts"
import { gesture } from "../runtime.ts"

const isDir = (e: Entry) => kindGroup(e) === "folder"

type FollowOptions = { onOpen?: (l: Location) => void; pick?: (rs: ReturnType<typeof roots>) => Location | null; requests?: boolean }

/** Opens sidebar navigation requests in `b` (unless `requests` is false), and a default root when nothing is open yet. */
function follow(b: Browser, o: FollowOptions = {}) {
  const onOpen = o.onOpen ?? ((l: Location) => b.open(l))
  const pick = o.pick ?? firstRoot
  let seen = 0
  if (o.requests !== false) {
    effect(() => {
      const r = request()
      if (r && r.seq !== seen) {
        seen = r.seq
        onOpen(r.location)
      }
    })
  }
  let opened = false
  effect(() => {
    const rs = roots()
    if (opened || b.location() || (o.requests !== false && request())) return
    const l = pick(rs)
    if (l) {
      opened = true
      onOpen(l)
    }
  })
}

const firstRoot = (rs: ReturnType<typeof roots>): Location | null => {
  const r = rs.find((x) => x.kind === "home") ?? rs[0]
  return r ? { conn: r.conn, root: r.root, path: "" } : null
}

function listBody(b: Browser, compact = false) {
  return VStack({ spacing: 0 }, [newFolderRow(b), ForEach({ items: b.rows, key: (e) => e.name }, (e) => entryRow(b, e, compact)), pager(b)])
}

function listColumn(b: Browser, compact = false) {
  return VStack({ spacing: 0 }, [listHeader(b, compact), Divider(), listState(b, () => listBody(b, compact)), Spacer(), statusLine(b)]).frame({ maxWidth: "infinity", maxHeight: "infinity" })
}

export function listPreviewView(showPreview: () => boolean) {
  const b = createBrowser({ pageRows: 22 })
  const preview = createPreview(b)
  follow(b)
  return VStack({ spacing: 0 }, [
    pathBar(b, toolbar(b)),
    Divider(),
    noticeRow(),
    HStack({ spacing: 0 }, [
      listColumn(b),
      () => (showPreview() ? HStack({ spacing: 0 }, [Divider(), VStack({ spacing: 0 }, [previewPane(preview), Spacer()]).frame({ width: 260, maxHeight: "infinity" })]) : null)
    ]).frame({ maxHeight: "infinity" }),
    jobsStrip()
  ])
}

// ---- columns ----------------------------------------------------------------

const MAX_COLUMNS = 6
const VISIBLE_COLUMNS = 3

function columnRow(b: Browser, e: CmuxSignal<Entry>, openNext: (name: string) => void) {
  return Row({
    title: () => e().name,
    symbol: () => (isDir(e()) ? "folder" : "doc"),
    selected: () => b.selection().includes(e().name),
    accessory: () => (isDir(e()) ? "chevron.right" : null)
  }).onTap(() => {
    const name = e().name
    b.select(name)
    if (isDir(e())) openNext(name)
  })
}

export function columnsView() {
  const cols: Browser[] = Array.from({ length: MAX_COLUMNS }, () => createBrowser({ pageRows: 22 }))
  const [depth, setDepth] = signal(1)
  // The last column (any depth) shows its own selection as the preview.
  const last = () => cols[depth() - 1]!
  const preview = createPreview({ selected: () => last().selected(), location: () => last().location() })

  const openAt = (i: number, l: Location) => {
    cols[i]!.open(l)
    for (let k = i + 1; k < MAX_COLUMNS; k++) cols[k]!.reset()
    setDepth(i + 1)
  }
  const openNext = (i: number) => (name: string) => {
    const l = cols[i]!.location()
    if (l && i + 1 < MAX_COLUMNS) openAt(i + 1, { ...l, path: join(l.path, name) })
  }
  follow(cols[0]!, { onOpen: (l) => openAt(0, l) })

  const column = (i: number) => {
    const visible = computed(() => i < depth() && i >= depth() - VISIBLE_COLUMNS)
    return () =>
    visible()
      ? HStack({ spacing: 0 }, [
          VStack({ spacing: 0 }, [listState(cols[i]!, () => VStack({ spacing: 0 }, [ForEach({ items: cols[i]!.rows, key: (e) => e.name }, (e) => columnRow(cols[i]!, e, openNext(i))), pager(cols[i]!)])), Spacer()])
            .padding(4)
            .frame({ width: 210, maxHeight: "infinity" }),
          Divider()
        ])
      : null
  }

  return VStack({ spacing: 0 }, [
    () => pathBar(last(), []),
    Divider(),
    noticeRow(),
    HStack({ spacing: 0 }, [...cols.map((_, i) => column(i)), VStack({ spacing: 0 }, [previewPane(preview), Spacer()]).frame({ maxWidth: "infinity", maxHeight: "infinity" })]).frame({ maxHeight: "infinity" }),
    jobsStrip()
  ])
}

// ---- dual pane ----------------------------------------------------------------

export function dualPaneView() {
  const left = createBrowser({ pageRows: 22 })
  const right = createBrowser({ pageRows: 22 })
  follow(left)
  // The right side starts on another connection when there is one, so cross-host copy is one click.
  follow(right, {
    requests: false,
    pick: (rs) => {
      const leftConn = left.location()?.conn ?? rs[0]?.conn
      const other = rs.find((r) => r.conn !== leftConn && conns().some((c) => c.conn === r.conn && c.state === "connected")) ?? rs[0]
      return other ? { conn: other.conn, root: other.root, path: "" } : null
    }
  })
  const side = (b: Browser) => VStack({ spacing: 0 }, [pathBar(b, toolbar(b, { filter: false })), Divider(), listColumn(b, true)]).frame({ maxWidth: "infinity", maxHeight: "infinity" })
  const send = (op: "copy" | "move", from: Browser, to: Browser) => () => {
    const g = gesture()
    const l = to.location()
    if (l) void transfer(op, from, from.selection(), l, to.root()?.rights === "read_write", g)
  }
  const none = (b: Browser) => () => b.selection().length === 0 || !b.location()
  return VStack({ spacing: 0 }, [
    HStack({ spacing: 6 }, [
      Spacer(),
      Button(t("dual.copyRight", "Copy →"), send("copy", left, right)).disabled(none(left)),
      Button(t("dual.moveRight", "Move →"), send("move", left, right)).disabled(none(left)),
      Divider().frame({ height: 14 }),
      Button(t("dual.copyLeft", "← Copy"), send("copy", right, left)).disabled(none(right)),
      Button(t("dual.moveLeft", "← Move"), send("move", right, left)).disabled(none(right)),
      Spacer()
    ]).padding({ top: 6, bottom: 6 }),
    Divider(),
    noticeRow(),
    HStack({ spacing: 0 }, [side(left), Divider(), side(right)]).frame({ maxHeight: "infinity" }),
    jobsStrip()
  ])
}
