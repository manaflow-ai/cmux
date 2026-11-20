// Two sessions driving one tab: while one holds a mouse button down, the
// other's mouse input waits, but not forever. It either runs (the dev
// driver has no per-session pointer owner) or fails with an error naming
// the holder after a bounded wait (the app); it never hangs until the
// evaluation times out. Sessions share only the user's tabs, so a one-shot
// run opens the tab and keeps it: once that run ends the tab is the user's
// and both sessions may drive it.
// oracle: skip (sessions sharing a tab are cmux-defined)
// ---- cell
const keptForUser = await tabs.open(`${PRIMARY}/input.html?pointer-owner`);
await keptForUser.keep();
// ---- cell session=holder
const heldRow = (await tabs.list({ all: true })).find((t) => t.url.endsWith("/input.html?pointer-owner"));
const held = await tabs.use(heldRow.id);
await held.mouse.move(5, 5);
await held.mouse.down();
emitCmux("held", true);
// ---- cell session=other
const shared = (await tabs.list({ all: true })).find((t) => t.url.endsWith("/input.html?pointer-owner"));
const other = await tabs.use(shared.id);
const started = Date.now();
let message = null;
try {
  await other.mouse.click(10, 10);
} catch (e) {
  message = e.message;
}
emitCmux("bounded", Date.now() - started < 60_000);
emitCmux("names-holder", message === null || /holds the mouse/.test(message));
// ---- cell session=holder
await held.mouse.up();
emitCmux("released", true);
await held.close();
