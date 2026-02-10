import type { Metadata } from "next";
import { CodeBlock } from "../../components/code-block";

export const metadata: Metadata = {
  title: "Concepts",
  description:
    "How cmux organizes terminals: windows, workspaces, panes, and surfaces. The hierarchy behind the sidebar, splits, and socket API.",
};

export default function ConceptsPage() {
  return (
    <>
      <h1>Concepts</h1>
      <p>
        cmux organizes your terminals in a four-level hierarchy. Understanding
        these levels helps when using the socket API, CLI, and keyboard
        shortcuts.
      </p>

      <h2>Hierarchy</h2>
      <CodeBlock lang="text">{`Window
  └── Workspace (sidebar entry)
        └── Pane (split region)
              └── Surface (tab within pane)
                    └── Panel (terminal or browser content)`}</CodeBlock>

      <h3>Window</h3>
      <p>
        A macOS window. Open multiple windows with <code>⌘⇧N</code>. Each
        window has its own sidebar with independent workspaces.
      </p>

      <h3>Workspace</h3>
      <p>
        A sidebar entry. Each workspace contains one or more split panes.
        Workspaces are what you see listed in the left sidebar.
      </p>
      <p>
        In the UI and keyboard shortcuts, workspaces are often called
        &ldquo;tabs&rdquo; since they behave like tabs in the sidebar. The
        socket API and environment variables use the term
        &ldquo;workspace&rdquo;.
      </p>

      <table>
        <thead>
          <tr>
            <th>Context</th>
            <th>Term used</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Sidebar UI</td>
            <td>Tab</td>
          </tr>
          <tr>
            <td>Keyboard shortcuts</td>
            <td>Workspace or tab</td>
          </tr>
          <tr>
            <td>Socket API</td>
            <td>
              <code>workspace</code>
            </td>
          </tr>
          <tr>
            <td>Environment variable</td>
            <td>
              <code>CMUX_WORKSPACE_ID</code>
            </td>
          </tr>
        </tbody>
      </table>

      <p>
        <strong>Shortcuts:</strong> <code>⌘N</code> (new),{" "}
        <code>⌘1</code>–<code>⌘9</code> (jump), <code>⌘⇧W</code> (close),{" "}
        <code>⌘⇧[</code> / <code>⌘⇧]</code> (prev/next)
      </p>

      <h3>Pane</h3>
      <p>
        A split region within a workspace. Created by splitting with{" "}
        <code>⌘D</code> (right) or <code>⌘⇧D</code> (down). Navigate between
        panes with <code>⌥⌘</code> + arrow keys.
      </p>
      <p>Each pane can hold multiple surfaces (tabs within the pane).</p>

      <h3>Surface</h3>
      <p>
        A tab within a pane. Each pane has its own tab bar and can hold multiple
        surfaces. Created with <code>⌘T</code>, navigated with{" "}
        <code>⌘[</code> / <code>⌘]</code> or <code>⌃1</code>–
        <code>⌃9</code>.
      </p>
      <p>
        Surfaces are the individual terminal or browser sessions you interact
        with. Each surface has its own <code>CMUX_SURFACE_ID</code> environment
        variable.
      </p>

      <h3>Panel</h3>
      <p>The content inside a surface. Currently two types:</p>
      <ul>
        <li>
          <strong>Terminal</strong> — a Ghostty terminal session
        </li>
        <li>
          <strong>Browser</strong> — an embedded web view
        </li>
      </ul>
      <p>
        Panel is mostly an internal concept. In the socket API and CLI, you
        interact with surfaces rather than panels directly.
      </p>

      <h2>Visual example</h2>
      <CodeBlock variant="ascii">{`┌──────────────────────────────────────────────────────┐
│ ┌──────────┐ ┌─────────────────────────────────────┐ │
│ │ Sidebar  │ │ Workspace "dev"                     │ │
│ │          │ │                                     │ │
│ │          │ │ ┌───────────────┬─────────────────┐ │ │
│ │ > dev    │ │ │ Pane 1        │ Pane 2          │ │ │
│ │   server │ │ │ [S1] [S2]     │ [S1]            │ │ │
│ │   logs   │ │ │               │                 │ │ │
│ │          │ │ │  Terminal     │  Terminal       │ │ │
│ │          │ │ │               │                 │ │ │
│ │          │ │ └───────────────┴─────────────────┘ │ │
│ └──────────┘ └─────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘`}</CodeBlock>
      <p>In this example:</p>
      <ul>
        <li>
          The <strong>window</strong> contains a sidebar with three workspaces
          (dev, server, logs)
        </li>
        <li>
          <strong>Workspace &ldquo;dev&rdquo;</strong> is selected, showing two{" "}
          <strong>panes</strong> side by side
        </li>
        <li>
          <strong>Pane 1</strong> has two <strong>surfaces</strong> ([S1] and
          [S2] in the tab bar), with S1 active
        </li>
        <li>
          <strong>Pane 2</strong> has one surface
        </li>
        <li>
          Each surface contains a <strong>panel</strong> (a terminal in this
          case)
        </li>
      </ul>

      <h2>Summary</h2>
      <table>
        <thead>
          <tr>
            <th>Level</th>
            <th>What it is</th>
            <th>Created by</th>
            <th>Identified by</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Window</td>
            <td>macOS window</td>
            <td>
              <code>⌘⇧N</code>
            </td>
            <td>—</td>
          </tr>
          <tr>
            <td>Workspace</td>
            <td>Sidebar entry</td>
            <td>
              <code>⌘N</code>
            </td>
            <td>
              <code>CMUX_WORKSPACE_ID</code>
            </td>
          </tr>
          <tr>
            <td>Pane</td>
            <td>Split region</td>
            <td>
              <code>⌘D</code> / <code>⌘⇧D</code>
            </td>
            <td>Pane ID (socket API)</td>
          </tr>
          <tr>
            <td>Surface</td>
            <td>Tab within pane</td>
            <td>
              <code>⌘T</code>
            </td>
            <td>
              <code>CMUX_SURFACE_ID</code>
            </td>
          </tr>
          <tr>
            <td>Panel</td>
            <td>Terminal or browser</td>
            <td>Automatic</td>
            <td>Panel ID (internal)</td>
          </tr>
        </tbody>
      </table>
    </>
  );
}
