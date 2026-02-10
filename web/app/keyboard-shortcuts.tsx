export function KeyboardShortcuts() {
  return (
    <section className="mb-12">
      <h2 className="text-xs font-medium text-muted tracking-tight mb-6">
        Keyboard Shortcuts
      </h2>
      <div className="space-y-8 text-[15px]">
        {/* Workspaces */}
        <div>
          <h3 className="text-[11px] uppercase tracking-widest text-muted/60 mb-3">Workspaces</h3>
          <ul className="space-y-3">
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ N</span>
              <span className="text-muted">New workspace</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ 1 – 8</span>
              <span className="text-muted">Jump to workspace 1–8</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ 9</span>
              <span className="text-muted">Jump to last workspace</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ ⇧ W</span>
              <span className="text-muted">Close workspace</span>
            </li>
          </ul>
        </div>

        {/* Surfaces */}
        <div>
          <h3 className="text-[11px] uppercase tracking-widest text-muted/60 mb-3">Surfaces</h3>
          <ul className="space-y-3">
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ T</span>
              <span className="text-muted">New surface</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ ⇧ [</span>
              <span className="text-muted">Previous surface</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌃ ⇧ Tab</span>
              <span className="text-muted">Previous surface</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌃ 1 – 8</span>
              <span className="text-muted">Jump to surface 1–8</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌃ 9</span>
              <span className="text-muted">Jump to last surface</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ W</span>
              <span className="text-muted">Close surface</span>
            </li>
          </ul>
        </div>

        {/* Split Panes */}
        <div>
          <h3 className="text-[11px] uppercase tracking-widest text-muted/60 mb-3">Split Panes</h3>
          <ul className="space-y-3">
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ D</span>
              <span className="text-muted">Split right</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ ⇧ D</span>
              <span className="text-muted">Split down</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌥ ⌘ ← → ↑ ↓</span>
              <span className="text-muted">Focus pane directionally</span>
            </li>
          </ul>
        </div>

        {/* Browser */}
        <div>
          <h3 className="text-[11px] uppercase tracking-widest text-muted/60 mb-3">Browser</h3>
          <ul className="space-y-3">
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ ⇧ B</span>
              <span className="text-muted">Open browser in split</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ L</span>
              <span className="text-muted">Focus address bar</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ ]</span>
              <span className="text-muted">Forward</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ R</span>
              <span className="text-muted">Reload page</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌥ ⌘ I</span>
              <span className="text-muted">Open Developer Tools</span>
            </li>
          </ul>
        </div>

        {/* Notifications */}
        <div>
          <h3 className="text-[11px] uppercase tracking-widest text-muted/60 mb-3">Notifications</h3>
          <ul className="space-y-3">
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ ⇧ I</span>
              <span className="text-muted">Show notifications panel</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ ⇧ U</span>
              <span className="text-muted">Jump to latest unread</span>
            </li>
          </ul>
        </div>

        {/* Find */}
        <div>
          <h3 className="text-[11px] uppercase tracking-widest text-muted/60 mb-3">Find</h3>
          <ul className="space-y-3">
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ F</span>
              <span className="text-muted">Find</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ G &nbsp;/&nbsp; ⌘ ⇧ G</span>
              <span className="text-muted">Find next / previous</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ ⇧ F</span>
              <span className="text-muted">Hide find bar</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ E</span>
              <span className="text-muted">Use selection for find</span>
            </li>
          </ul>
        </div>

        {/* Terminal */}
        <div>
          <h3 className="text-[11px] uppercase tracking-widest text-muted/60 mb-3">Terminal</h3>
          <ul className="space-y-3">
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ K</span>
              <span className="text-muted">Clear scrollback</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ C</span>
              <span className="text-muted">Copy (with selection)</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ V</span>
              <span className="text-muted">Paste</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ + &nbsp;/&nbsp; ⌘ -</span>
              <span className="text-muted">Increase / decrease font size</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ 0</span>
              <span className="text-muted">Reset font size</span>
            </li>
          </ul>
        </div>

        {/* Window */}
        <div>
          <h3 className="text-[11px] uppercase tracking-widest text-muted/60 mb-3">Window</h3>
          <ul className="space-y-3">
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ ⇧ N</span>
              <span className="text-muted">New window</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ ,</span>
              <span className="text-muted">Settings</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ ⇧ R</span>
              <span className="text-muted">Reload configuration</span>
            </li>
            <li className="flex items-baseline justify-between">
              <span className="font-mono text-[13px]">⌘ Q</span>
              <span className="text-muted">Quit</span>
            </li>
          </ul>
        </div>
      </div>
    </section>
  );
}
