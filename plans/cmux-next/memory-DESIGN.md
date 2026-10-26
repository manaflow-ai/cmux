# cmux NEXT memory: Memory Saver, budgets from RAM, one coordinator per process

Owner: PL-memory ([OWNERS.md](OWNERS.md)). The program spec is
[chrome-parity/p07-memory.md](chrome-parity/p07-memory.md). Task 007 writes the design sections of this
file; this section is task 110's (when both land, keep 007's sections and put this one after section 7,
"Measurement").

## Hidden Chromium pages: backgrounded and purged

Question: does a hidden Chromium page in cmux give back memory the way a hidden tab does in Chrome,
before any hibernation closes it?

### What Chrome does

1. A renderer process whose frames are all hidden, with no audio, capture or foreground worker, gets
   a lower priority: `RenderProcessHostImpl::UpdateProcessPriority`
   (`content/browser/renderer_host/render_process_host_impl.cc`). On macOS `Process::SetPriority`
   (`base/process/process_mac.cc`) sets the task role `TASK_BACKGROUND_APPLICATION` for it, and
   `TASK_FOREGROUND_APPLICATION` again when a frame shows.
2. The renderer learns it is backgrounded (`RenderThreadImpl::OnRendererBackgrounded`) and
   `blink::MemoryPurgeManager` (`memory_purge_manager.cc`) purges V8, PartitionAlloc and Skia memory
   at a random time 1 to 4 minutes later, and at once when all of its pages are frozen.
3. A frame is hidden when its `WebContents` is hidden: `WebContentsImpl::UpdateWebContentsVisibility`
   (`content/browser/web_contents/web_contents_impl.cc`), fed on macOS by the view's hide and by window
   occlusion (`content/app_shim_remote_cocoa/web_contents_occlusion_checker_mac.mm`).

In cmux, `CEFTab+Freeze.swift` says `CefBrowserHost::WasHidden` does nothing for a windowed
Chrome-style browser. If Chromium never counts a hidden cmux page as hidden, step 1 never runs, the
renderer keeps its foreground role, and step 2 never purges. Freezing (`browser.freezeHiddenTabs`)
then saves CPU but not memory.

### The measurement

`scripts/cmux-next/bench_hibernation.py --background-timeline 0,30,300,600` (task 110). Hibernation is
off for the run, so every page stays loaded. For each freeze mode (`off`, then `on` at `--freeze`
seconds) the bench opens `--tabs` Chromium pages, each its own site (`tN.localhost`, so each has its
own renderer under site isolation, with a `--heap-mb` array as a site's heap), and hides them behind
one shown tab. At 0 s, 30 s, 5 min and 10 min after the hide it reads, for each hidden page, the
footprint (PMF, `phys_footprint` from `proc_pid_rusage`) of the renderer that hosts that page and no
other (from the app's `resources` report), and that renderer's task role.

The task role comes from the task's base priority (`proc_pidinfo PROC_PIDTASKINFO`, `pti_priority`):
47 foreground, 46 background, 31 default (no role set), 4 or lower throttled (xnu
`osfmk/kern/sched.h`, `task_policy.c`). The bench prints one line per mode and point:

```text
PERF-HIBERNATE-BACKGROUND freeze=off at_s=300 measured_at_s=300.0 per_hidden_tab_pmf_mb=... max_hidden_tab_pmf_mb=...
    renderer_task_role=background:6 front_task_role=foreground frozen=0/6 measured=6/6
```

then one `PERF-HIBERNATE-BACKGROUND-SUMMARY` line per mode (PMF at the four points, `fell_mb`,
`fell_pct`, `backgrounded`, the roles at 30 s), and a verdict:

- `backgrounded`: every measured hidden renderer has the background or throttled role at 30 s.
- `pmf_falls`: the per-page PMF at 10 min is at least 10 % below the PMF at 0 s.
- `follow_up=none` when both are true in every mode, else `follow_up=shim-visibility`.

The bench's last script call into each page starts the 30 s agent grace, so with freezing on a page
freezes at the later of `--freeze` and 30 s; the `frozen=` count at each point shows when.

Command (fleet, exclusive):

```bash
cmux-ci run --class exclusive --measurement --label measure --ref SHA \
  --script 'scripts/cmux-next/bench_hibernation.py --app BUNDLE --background-timeline 0,30,300,600 --tabs 6 --out background.json'
```

### Result

Not run yet. The lead's fleet measurement round records host, SHA, step ID and the numbers here.

| Freeze | 0 s PMF MB | 30 s | 5 min | 10 min | Role at 30 s | Frozen at 10 min | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| off | | | | | | | |
| on | | | | | | | |

### Follow-up when the PMF does not fall

When the verdict is `follow_up=shim-visibility`, file this task in p07-memory:

- Title: hidden Chromium pages reach Chromium as hidden.
- Files: the cef-cmux fork (a `cmux_shim_tab_set_hidden` that calls
  `WebContentsImpl::UpdateWebContentsVisibility` for a windowed Chrome-style browser),
  `CEF/Shim/cmux_cef_shim.h`, `CEFTab+Freeze.swift` and `CEFPaneHost.swift` (send hidden and shown
  with the host view's visibility, and occlusion from `WindowDrawPolicy`), behind a fork API check.
- Acceptance: this bench shows `backgrounded=True` at 30 s and `pmf_falls=True` in both freeze modes;
  the shown tab's renderer stays foreground; a shown tab paints its first frame within the tab-switch
  budget (`bench-tab-switch.sh`, not worse).
- Test: fleet exclusive, this bench before and after.
