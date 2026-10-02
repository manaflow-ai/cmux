// A tiny DOM for controller tests (bun has no DOM): elements with children,
// text, classes, hidden, click listeners and style properties.
export class FakeElement {
  children: FakeElement[] = []
  className = ""
  hidden = false
  disabled = false
  type = ""
  dataset: Record<string, string> = {}
  private text = ""
  private listeners = new Map<string, Array<() => void>>()
  readonly styleProps = new Map<string, string>()
  readonly style = { setProperty: (k: string, v: string) => this.styleProps.set(k, v) }
  readonly classList = {
    toggle: (c: string, on: boolean) => {
      const set = new Set(this.className.split(" ").filter(Boolean))
      if (on) set.add(c)
      else set.delete(c)
      this.className = [...set].join(" ")
    },
    contains: (c: string) => this.className.split(" ").includes(c)
  }
  constructor(readonly tag: string) {}
  get textContent(): string {
    return this.text + this.children.map((c) => c.textContent).join("")
  }
  set textContent(v: string) {
    this.text = v
    this.children = []
  }
  append(...nodes: FakeElement[]) {
    this.children.push(...nodes)
  }
  remove() {}
  addEventListener(type: string, fn: () => void) {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), fn])
  }
  click() {
    for (const fn of this.listeners.get("click") ?? []) fn()
  }
  /** Visible text, skipping hidden subtrees. */
  visibleText(): string {
    if (this.hidden) return ""
    return [this.text, ...this.children.map((c) => c.visibleText())].filter(Boolean).join(" ")
  }
  find(pred: (e: FakeElement) => boolean): FakeElement | undefined {
    if (pred(this)) return this
    for (const c of this.children) {
      const f = c.find(pred)
      if (f) return f
    }
    return undefined
  }
}

export function fakeDocument() {
  const documentElement = new FakeElement("html")
  return { documentElement, createElement: (tag: string) => new FakeElement(tag) }
}
