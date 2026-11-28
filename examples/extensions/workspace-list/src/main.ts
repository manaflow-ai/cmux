// Workspace list: the built-in workspace list, rebuilt on the public SDK so you can copy it and
// change it. It imports nothing but cmux-extension-sdk.
// - The whole list (cmux.sidebar/1, `renderSidebar`): cmux draws it in place of the built-in list
//   once you set `"sidebar.workspaceListApp": "local/workspace-list"` in cmux-next.json. While it
//   loads, fails or is removed, cmux draws its own list.
// - The same list as a section (cmux.section/1, `renderSection`), to place beside the built-in one.
// Each row is one workspace, in your order; the one you are in is selected; the badge counts the
// chats in it that wait for you. Click a row to show that workspace. The lists re-read when cmux
// pushes workspace.changed and agent_chat.changed; nothing polls.

import { chats, cmux, computed, EmptyState, ForEach, Row, section, sidebar, VStack, workspaces, type Chat, type View } from "cmux-extension-sdk"

const waiting = (c: Chat) => c.state === "input" || c.unread

function list(): View {
  const spaces = workspaces()
  const chatList = chats()
  // One pass over the chats per change, not one per row.
  const waitingBy = computed(() => {
    const counts = new Map<string, number>()
    for (const c of chatList() ?? []) if (c.workspace && waiting(c)) counts.set(c.workspace, (counts.get(c.workspace) ?? 0) + 1)
    return counts
  })
  return VStack({ spacing: 0 }, [
    ForEach({ items: () => spaces() ?? [], key: (w) => w.id }, (w) =>
      Row({
        title: () => w().name,
        symbol: () => (w().focused ? "rectangle.inset.filled" : "rectangle"),
        badge: () => waitingBy().get(w().id) || null,
        selected: () => w().focused
      }).onTap(() => cmux.workspace.focus({ workspace: w().id }))
    ),
    () => (spaces.error() ? EmptyState({ title: "Can't read workspaces", message: spaces.error()!.message, symbol: "exclamationmark.triangle" }) : null)
  ])
}

export const renderSidebar = sidebar(list)
export const renderSection = section(list)
