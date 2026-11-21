// The transcript's Tab guard (ui/tabReach.ts keepTabOnScreen) over a plain scroller, scrolled so
// that `above` and `below` are out of view and `mid` and the players beside it are in it.
import { keepTabOnScreen } from "../../src/ui/tabReach";

const region = document.getElementById("region")!;
keepTabOnScreen(region);
const back = document.getElementById("back")!;
region.scrollTop = back.offsetTop - region.offsetTop - 40;
// Whether the page took the last Tab press: read after the guard, which was installed first.
const record = window as unknown as { lastTabPrevented?: boolean };
document.addEventListener("keydown", (event) => {
  if (event.key === "Tab") record.lastTabPrevented = event.defaultPrevented;
});
document.documentElement.dataset.harnessReady = "1";
