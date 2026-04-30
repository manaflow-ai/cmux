import React from "react"
import { createRoot } from "react-dom/client"
import { App } from "./App"
import "./styles.css"
import "diff2html/bundles/css/diff2html.min.css"

declare global {
  interface Window {
    webkit?: {
      messageHandlers: {
        cmuxTurnDiff?: { postMessage: (msg: unknown) => void }
      }
    }
    cmuxBridge?: { post: (msg: unknown) => void }
  }
}

window.cmuxBridge = {
  post: (msg) => {
    window.webkit?.messageHandlers?.cmuxTurnDiff?.postMessage(msg)
  },
}

const root = createRoot(document.getElementById("root")!)
root.render(<App />)
