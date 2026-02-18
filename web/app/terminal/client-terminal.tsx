"use client"

import dynamic from "next/dynamic"

const TerminalPage = dynamic(
  () => import("./terminal-page").then((m) => m.TerminalPage),
  { ssr: false },
)

export function ClientTerminal() {
  return <TerminalPage />
}
