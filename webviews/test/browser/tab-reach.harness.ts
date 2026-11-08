// The transcript's Tab guard (ui/tabReach.ts keepTabOnScreen) over a plain scroller, scrolled so
// that `above` and `below` are out of view and `mid` and the players beside it are in it.
import { keepTabOnScreen } from "../../src/ui/tabReach";

const region = document.getElementById("region")!;
keepTabOnScreen(region);
const video = document.getElementById("video")!;
region.scrollTop = video.offsetTop - region.offsetTop - 40;
document.documentElement.dataset.harnessReady = "1";
