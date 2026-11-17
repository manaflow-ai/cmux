// The preview page's stand-in for cmux: GitHub answers from fixtures.ts, storage in memory,
// links logged. `preview/index.html?variant=index&rfd=2&comments=slow` picks the state to show.
import { answer } from "./fixtures"

const params = new URLSearchParams(location.search)
const store = new Map<string, unknown>()
if (params.get("variant")) store.set("variant", params.get("variant"))
const delay = (ms: number) => new Promise((r) => setTimeout(r, ms))

;(globalThis as Record<string, unknown>).__RFD_PREVIEW_HOST__ = {
  async get(path: string) {
    // Comments arrive after the text, as they do from GitHub.
    await delay(path.includes("/comments") ? Number(params.get("commentDelay") ?? 400) : 20)
    return structuredClone(answer(path))
  },
  async load(key: string) {
    return store.has(key) ? structuredClone(store.get(key)) : null
  },
  async save(key: string, value: unknown) {
    store.set(key, structuredClone(value))
  },
  open(url: string) {
    console.log(`open ${url}`)
  },
}
