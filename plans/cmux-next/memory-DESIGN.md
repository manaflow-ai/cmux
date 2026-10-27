# cmux NEXT memory: Memory Saver, budgets from RAM, one coordinator per process

Owner: PL-memory ([OWNERS.md](OWNERS.md)). The program spec is
[chrome-parity/p07-memory.md](chrome-parity/p07-memory.md). Task 007 writes the design sections of this
file; this section is task 110's. When both land, keep 007's sections and put this one after section 7,
"Measurement".

## Hidden Chromium pages: backgrounded and purged

Question: does a hidden Chromium page in cmux give back memory the way a hidden tab does in Chrome,
before any hibernation closes it?

### What Chrome does

1. A renderer process whose frames are all hidden, with no audio, capture or foreground worker, gets
   `Priority::kBestEffort`: `RenderProcessHostImpl::UpdateProcessPriority`
   (`content/browser/renderer_host/render_process_host_impl.cc`). On macOS `Process::SetPriority`
   (`base/process/process_mac.cc`) then sets the task role `TASK_BACKGROUND_APPLICATION` and a
   `TASK_SUPPRESSION_POLICY` (low CPU priority, timer and throughput throttling), and
   `TASK_FOREGROUND_APPLICATION` with no suppression again when a frame shows.
2. The renderer learns it is backgrounded (`RenderThreadImpl::OnRendererBackgrounded`) and
   `blink::MemoryPurgeManager` (`third_party/blink/renderer/core/timing/memory_purge_manager.cc`) purges
   V8, PartitionAlloc and Skia memory at a random time 1 to 4 minutes later, and at once when all of its
   pages are frozen.
3. A frame is hidden when its `WebContents` is hidden: `WebContentsImpl::UpdateWebContentsVisibility`
   (`content/browser/web_contents/web_contents_impl.cc`), fed on macOS by the view's hide and by window
   occlusion (`content/app_shim_remote_cocoa/web_contents_occlusion_checker_mac.mm`).

In cmux, `CefBrowserHost::WasHidden` does nothing for a windowed Chrome-style browser
(`CEFTabNodeVisibility.swift`). If Chromium never counts a hidden cmux page as hidden, step 1 never
runs, the renderer keeps its foreground role, and step 2 never purges. Freezing
(`browser.freezeHiddenTabs`) then saves CPU but not memory. The fork's `cmux_tab_set_visibility`
(fork API 37, p06-scheduler-212) sends a tab's hide to `UpdateWebContentsVisibility`, but only with
the default-off feature `chromiumTabVisibility` and a fork pin at API 37 or later. So the bench runs
twice: with the feature off (what people get today) and on.

### The measurement

`scripts/cmux-next/bench_hibernation.py --background-timeline 0,30,300,600`. Hibernation is off for
the run, so every page stays loaded. For each freeze mode (`off`, then `on` at `--freeze` seconds) the
bench opens `--tabs` Chromium pages, each its own site (`tN.localhost`, so each has its own renderer
under site isolation, with a `--heap-mb` array as a site's heap), and hides them behind one shown tab.
At 0 s, 30 s, 5 min and 10 min after the hide it reads, for each hidden page, the footprint of the
renderer that hosts that page and no other (from the app's `resources` report), and that renderer's
task role.

- PMF is `phys_footprint` from `proc_pid_rusage`, the number Chrome reports as private memory footprint
  on macOS (`components/metrics/process_memory_metrics_emitter.cc`).
- The task role is read the way the idle audit reads it (`idle-budget.py` `observed_role` over
  `scripts/perf-bench/procs.py` `priorities`, same user, no task port): `darwinbg` (the kernel's
  darwin-background bit), `suppressed` (a base priority below `BASEPRI_DEFAULT` 31: the suppression
  policy's low CPU priority, App Nap or a positive nice) or `default` (not lowered). The role itself
  changes thread QoS, not the base priority (xnu `osfmk/kern/task_policy.c`), so Chrome's background
  renderer shows as `suppressed` or `darwinbg`, a foreground one as `default`. The raw base priorities
  are printed too.

The bench first prints `PERF-HIBERNATE-BACKGROUND-START chromiumTabVisibility=<state> fork_api=<n>`
(the state from `features.list`, the API from `debug.cef`). Below fork API 37 the feature makes no
call, so a run with it on measures the same as off. Then one line per mode and point:

```text
PERF-HIBERNATE-BACKGROUND freeze=off at_s=300 measured_at_s=300.0 per_hidden_tab_pmf_mb=... max_hidden_tab_pmf_mb=...
    renderer_task_role=suppressed:6 renderer_base_priority=4,4,4,4,4,4 front_task_role=default frozen=0/6 measured=6/6
```

then one `PERF-HIBERNATE-BACKGROUND-SUMMARY` line per mode (PMF at the four points, `fell_mb`,
`fell_pct`, `backgrounded`, the roles at 30 s), and a verdict:

- `backgrounded`: every measured hidden renderer has the `suppressed` or `darwinbg` role at 30 s.
- `pmf_falls`: the per-page PMF at 10 min is at least 10 % below the PMF at 0 s.
- `follow_up=none` when both are true in every mode, else `follow_up=shim-visibility`.

The bench's last script call into each page starts the 30 s agent grace, so with freezing on a page
freezes at the later of `--freeze` and 30 s; the `frozen=` count at each point shows when. The run
writes the report (`--out FILE.json`, key `background`) and no result-v1 series.

Commands (fleet, exclusive; one run is about 21 min: two freeze modes of 10 min each):

```bash
cmux-ci run --class exclusive --measurement --label measure --ref SHA \
  --script 'scripts/cmux-next/bench_hibernation.py --app BUNDLE --background-timeline 0,30,300,600 --tabs 6 --out background-off.json'
cmux-ci run --class exclusive --measurement --label measure --ref SHA \
  --script 'scripts/cmux-next/bench_hibernation.py --app BUNDLE --background-timeline 0,30,300,600 --tabs 6 --feature chromiumTabVisibility=on --out background-on.json'
```

### Result

Not run yet. The lead's fleet measurement round records host, SHA, step ID, `fork_api` and the
numbers here.

| chromiumTabVisibility | Freeze | 0 s PMF MB | 30 s | 5 min | 10 min | Role at 30 s | Frozen at 10 min | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| off | off | | | | | | | |
| off | on | | | | | | | |
| on | off | | | | | | | |
| on | on | | | | | | | |

### Follow-up when the PMF does not fall

Read the two runs together:

- Off gives `follow_up=shim-visibility` and on gives `follow_up=none` (fork API 37 or later): the fix
  exists. File a p07-memory task to turn `chromiumTabVisibility` on by default with these numbers,
  and tell its owner (PL-cef-tab).
- Both give `follow_up=shim-visibility`, or the pin is below API 37: file this task in p07-memory.
  - Title: hidden Chromium pages reach Chromium as hidden.
  - Files: the cef-cmux fork (`cmux_tab_set_visibility` reaches
    `WebContentsImpl::UpdateWebContentsVisibility` for a windowed Chrome-style browser, and the
    renderer's priority follows it as in `RenderProcessHostImpl::UpdateProcessPriority`),
    `CEF/Shim/cmux_cef_shim.h`, `CEFTabNodeVisibility.swift` and `CEFPaneHost.swift` (hidden and shown
    from the tab's visibility node, occlusion from `WindowDrawPolicy`), behind a fork API check.
  - Acceptance: this bench shows `backgrounded=True` at 30 s and `pmf_falls=True` in both freeze
    modes; the shown tab's renderer stays `default`; a shown tab paints its first frame within the
    tab-switch budget (`bench-tab-switch.sh`, not worse).
  - Test: fleet exclusive, this bench before and after.
