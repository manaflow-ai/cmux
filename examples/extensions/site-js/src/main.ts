// JavaScript for this site: a palette command that turns JavaScript off for the site in the front
// browser tab, or back on. It imports nothing but the public SDK.
// - site.javascript.get reads the site's setting: the same one as Page Info's JavaScript row.
// - site.javascript.set flips it with the command's gesture, and cmux reloads the site's open tabs.

import { cmux, command, site, type CommandContext } from "cmux-extension-sdk"

/** `https://www.example.com:8443` -> `www.example.com:8443`. */
export function hostOf(origin: string): string {
  return origin.replace(/^[a-z]+:\/\//i, "").replace(/\/.*$/, "")
}

/** What the toast says once the setting changed. */
export function notice(origin: string, allowed: boolean): string {
  return `JavaScript ${allowed ? "on" : "off"} for ${hostOf(origin)}`
}

const message = (error: unknown) => (error instanceof Error ? error.message : String(error))

/** The palette command (`local.showcase_site_js.toggle`): the site's new setting, or why it kept the old one. */
export const toggle = command(async (_args: unknown, ctx: CommandContext): Promise<{ origin: string; allowed: boolean } | { error: string }> => {
  try {
    const now = await site.javascript.get()
    const next = await site.javascript.set({ origin: now.origin, allowed: !now.allowed }, { gesture: ctx.gesture })
    await cmux.toast({ title: notice(next.origin, next.allowed), tone: next.allowed ? "success" : undefined })
    return next
  } catch (error) {
    await cmux.toast({ title: "Couldn't change JavaScript for this site", message: message(error), tone: "warning" })
    return { error: message(error) }
  }
})
