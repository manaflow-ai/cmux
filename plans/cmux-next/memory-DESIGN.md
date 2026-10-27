# cmux NEXT memory: Memory Saver, budgets from RAM, one coordinator per process

Owner: PL-memory ([OWNERS.md](OWNERS.md)). The full task list is the program spec
[chrome-parity/p07-memory.md](chrome-parity/p07-memory.md). Browser hibernation details (keep rules,
freeze, neighbors, wake) stay in [tab-lifecycle.md](tab-lifecycle.md) section 3. Task 007 fills in the
other sections of this file.

## Freezing hidden pages

### Why 30 seconds

A hidden Chromium page freezes after `browser.freezeHiddenTabs` seconds, 30 by default
(`BrowserHibernationSetting.defaultFreezeSeconds`). The timer is a power choice, not a memory one: a
frozen page keeps its memory and its state.

- A hidden page keeps its renderer awake about 0.5 to 1.5 times a second (msg 2654). Freezing it cut the
  renderer's energy by about 90 % on cmux14, and hibernation closes a page only after 60 minutes hidden.
  Chrome's own throttling of hidden pages (one wake-up a second at once, intensive throttling after 5
  minutes, `kIntensiveWakeUpThrottling`) leaves those wake-ups; a frozen page has none.
- 30 seconds is long enough for the work a page starts as the person leaves it (a send, a save, an
  upload's last request) to end, and for a quick look at another tab and back to find a live page.
  Pages the person switches to with one key (`browser.keepNeighborTabsAwake`) and a hovered tab stay
  awake whatever the timer, so the timer does not decide the cost of the next switch.
- Chrome's `FreezingPolicy` freezes hidden pages under its battery saver, pages above its high-CPU
  proportion (`kFreezingHighCPUProportion`); cmux freezes every hidden page that can freeze, since cmux keeps many more
  hidden pages (agents' pages, dashboards) than a person keeps background tabs. Energy Saver freezes a
  CPU-heavy hidden page before the delay (`SaverCPUFreeze`).

### What never freezes

Chrome's `CannotFreezeReason`s (`components/performance_manager/freezing/freezing_policy.cc`), behind
feature `memoryFreezeEligibility` (`FreezeEligibility`, `HibernationPlanner.freezePlan`): never freeze a
page whose site may show notifications, that holds a Web Lock or an open IndexedDB connection (Chrome:
a blocking IndexedDB lock; cmux has no engine hook for that yet, so any open connection counts), or that
still loads. The page's recorder counts the locks this document holds (`BrowserPageBusy`), as Chrome
counts them per frame; `navigator.locks.query()` would list every page of the origin. A page kept for its
load, or that starts to load before its freeze probe answers, is planned again when the load ends (an
observation, no timer).

An opener and the pages it opened freeze only when every one of them is due, and thaw together, as
Chrome freezes a browsing instance as a whole; the hibernation of one member thaws that page alone, as
Chrome discards a frozen page without unfreezing its group. The links are read once per plan, only when
a due page asks for its group. cmux's own reasons stay: pinned tabs, Never Hibernate
hosts, DevTools, capture, an agent's lease, background activity, playing media, Web Audio, WebRTC and
open devices.
