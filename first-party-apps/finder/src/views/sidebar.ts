// Sidebar section "Files": favorites (root handles), hosts (connection
// handles), recent places. Tapping a place opens it in the Finder pane.

import { type Conn, ops, type Root } from "../data/ops.ts"
import { t } from "../l10n.ts"
import { addRoot, conns, flash, loaded, navigate, recent, roots, sidebarError, upsertConn } from "../store.ts"
import { connectionTitle, isMissing } from "./common.ts"
import { gesture } from "../runtime.ts"

const groupTitle = (text: string) => Text(text).font("caption").weight("semibold").color("tertiary").padding({ top: 8, leading: 6, bottom: 2 })

export function connSubtitle(c: Conn): string | null {
  if (c.state === "connected") return c.path ?? null
  return connectionTitle(c.label, c.state)
}

export function connSymbol(c: Conn): string {
  switch (c.kind) {
    case "local":
      return "laptopcomputer"
    case "server":
      return "server.rack"
    case "team_vm":
      return "person.2"
    case "cloud_vm":
      return "cloud"
    default:
      return "terminal"
  }
}

/** Opens the root's top folder in the Finder pane (asks the shell to show the pane first). */
export function openRoot(r: Root) {
  const g = gesture()
  navigate({ conn: r.conn, root: r.root, path: "" })
  void ops.openPane(g)
}

export async function connect(conn?: string) {
  const g = gesture()
  const r = await ops.connect(g, conn)
  if (!r.ok) {
    if (r.error.code !== "user.cancelled") flash(isMissing(r.error.code) ? t("hosts.missing", "Connecting to hosts needs a newer cmux.") : r.error.message)
    return
  }
  upsertConn(r.value.conn)
}

export async function addFolder() {
  const g = gesture()
  const r = await ops.pickRoot(g)
  if (!r.ok) {
    if (r.error.code !== "user.cancelled") flash(isMissing(r.error.code) ? t("favorites.missing", "Adding folders needs a newer cmux.") : r.error.message)
    return
  }
  addRoot(r.value.root)
  openRoot(r.value.root)
}

function hostRow(c: CmuxSignal<Conn>) {
  return Row({
    title: () => c().label,
    subtitle: () => connSubtitle(c()),
    symbol: () => connSymbol(c()),
    tint: () => (c().state === "connected" ? null : c().state === "unreachable" ? "danger" : "tertiary"),
    accessory: () => (c().state === "connecting" || c().state === "verifying" ? "ellipsis" : null)
  })
    .onTap(() => {
      const conn = c()
      if (conn.state !== "connected") return void connect(conn.conn)
      const home = roots().find((r) => r.conn === conn.conn)
      if (home) openRoot(home)
    })
    .contextMenu(() => [
      Button(t("hosts.disconnect", "Disconnect"), () => void ops.disconnect(c().conn).then((r) => r.ok && upsertConn(r.value.conn))).disabled(c().state !== "connected" || c().kind === "local")
    ])
}

export function filesSection() {
  const favorites = () => roots().filter((r) => r.pinned !== false && conns().find((c) => c.conn === r.conn)?.kind !== "ssh")
  const missing = computed(() => isMissing(sidebarError()?.code))
  return VStack({ spacing: 0 }, [
    () =>
      missing()
        ? EmptyState({ title: t("sidebar.missing", "Files needs a newer cmux"), message: t("sidebar.missingHint", "This cmux cannot list folders or hosts for apps yet."), symbol: "puzzlepiece.extension" })
        : VStack({ spacing: 0 }, [
            groupTitle(t("sidebar.favorites", "Favorites")),
            ForEach({ items: favorites, key: (r) => r.root }, (r) =>
              Row({ title: () => r().label, subtitle: () => r().display, symbol: () => (r().kind === "home" ? "house" : r().kind === "workspace" ? "square.stack" : "folder") }).onTap(() => openRoot(r()))
            ),
            Row({ title: t("sidebar.addFolder", "Add Folder…"), symbol: "plus" }).onTap(() => void addFolder()),
            groupTitle(t("sidebar.hosts", "Hosts")),
            ForEach({ items: conns, key: (c) => c.conn }, (c) => hostRow(c)),
            Row({ title: t("sidebar.connect", "Connect to Host…"), symbol: "plus" }).onTap(() => void connect()),
            () =>
              recent().length === 0
                ? null
                : VStack({ spacing: 0 }, [
                    groupTitle(t("sidebar.recent", "Recent")),
                    ForEach({ items: () => recent().slice(0, 5), key: (r) => `${r.conn}|${r.root}|${r.path}` }, (r) =>
                      Row({ title: () => r().label, symbol: "clock" }).onTap(() => {
                        const g = gesture()
                        navigate(r())
                        void ops.openPane(g)
                      })
                    )
                  ])
          ]),
    () => (loaded() ? null : HStack([ProgressView(), Spacer()]).padding(8))
  ])
}
