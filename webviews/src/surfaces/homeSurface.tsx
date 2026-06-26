import { createRoot } from "react-dom/client";
import * as React from "react";
import homeStyles from "../home.css?inline";
import { installWebviewStyles } from "./installWebviewStyles";

type HomeAction = "newWorkspace" | "newBrowser" | "commandPalette" | "settings";

const actions: Array<{
  id: HomeAction;
  title: string;
  subtitle: string;
  icon: string;
}> = [
  {
    id: "newWorkspace",
    title: "New Workspace",
    subtitle: "Start a terminal workspace",
    icon: "terminal",
  },
  {
    id: "newBrowser",
    title: "Browser",
    subtitle: "Open a browser workspace",
    icon: "browser",
  },
  {
    id: "commandPalette",
    title: "Command Palette",
    subtitle: "Run commands and switch workspaces",
    icon: "command",
  },
  {
    id: "settings",
    title: "Settings",
    subtitle: "Open preferences",
    icon: "settings",
  },
];

function nativeHandler() {
  const handler = window.webkit?.messageHandlers?.cmuxHome;
  return handler && typeof handler.postMessage === "function" ? handler : null;
}

async function runHomeAction(action: HomeAction): Promise<void> {
  const handler = nativeHandler();
  if (!handler) {
    throw new Error("Home bridge is unavailable.");
  }
  const reply = await handler.postMessage({ action });
  if (!reply?.ok) {
    throw new Error(reply?.error?.code ?? "action_failed");
  }
}

function HomeSurface() {
  const [pendingAction, setPendingAction] = React.useState<HomeAction | null>(null);
  const [error, setError] = React.useState<string | null>(null);

  async function handleAction(action: HomeAction) {
    setPendingAction(action);
    setError(null);
    try {
      await runHomeAction(action);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Action failed.");
    } finally {
      setPendingAction(null);
    }
  }

  return (
    <main className="home-shell" aria-label="Home">
      <section className="home-header">
        <div className="home-mark" aria-hidden="true">
          <HomeGlyph name="home" />
        </div>
        <div className="home-heading">
          <h1>Home</h1>
          <p>Choose a workspace action.</p>
        </div>
      </section>

      <section className="home-actions" aria-label="Workspace actions">
        {actions.map((action) => (
          <button
            key={action.id}
            type="button"
            className="home-action"
            disabled={pendingAction != null}
            onClick={() => void handleAction(action.id)}
          >
            <span className={`home-action-icon home-action-icon-${action.id}`} aria-hidden="true">
              <HomeGlyph name={action.icon} />
            </span>
            <span className="home-action-copy">
              <span className="home-action-title">{action.title}</span>
              <span className="home-action-subtitle">{action.subtitle}</span>
            </span>
          </button>
        ))}
      </section>

      {error ? <p className="home-error" role="status">{error}</p> : null}
    </main>
  );
}

function HomeGlyph({ name }: { name: string }) {
  switch (name) {
  case "browser":
    return (
      <svg viewBox="0 0 20 20" focusable="false">
        <circle cx="10" cy="10" r="7" />
        <path d="M3.5 10h13" />
        <path d="M10 3a10 10 0 0 1 0 14" />
        <path d="M10 3a10 10 0 0 0 0 14" />
      </svg>
    );
  case "command":
    return (
      <svg viewBox="0 0 20 20" focusable="false">
        <path d="M7 7H5.5a2.5 2.5 0 1 1 2.5-2.5V7h4V4.5A2.5 2.5 0 1 1 14.5 7H13v4h1.5A2.5 2.5 0 1 1 12 13.5V12H8v1.5A2.5 2.5 0 1 1 5.5 11H7V7Z" />
      </svg>
    );
  case "settings":
    return (
      <svg viewBox="0 0 20 20" focusable="false">
        <circle cx="10" cy="10" r="2.5" />
        <path d="M10 2.8v2" />
        <path d="M10 15.2v2" />
        <path d="m4.9 4.9 1.4 1.4" />
        <path d="m13.7 13.7 1.4 1.4" />
        <path d="M2.8 10h2" />
        <path d="M15.2 10h2" />
        <path d="m4.9 15.1 1.4-1.4" />
        <path d="m13.7 6.3 1.4-1.4" />
      </svg>
    );
  case "terminal":
    return (
      <svg viewBox="0 0 20 20" focusable="false">
        <rect x="3" y="4" width="14" height="12" rx="2" />
        <path d="m6 8 2.5 2L6 12" />
        <path d="M10 12h4" />
      </svg>
    );
  default:
    return (
      <svg viewBox="0 0 20 20" focusable="false">
        <path d="M3.5 9.5 10 4l6.5 5.5" />
        <path d="M5 8.5V16h10V8.5" />
      </svg>
    );
  }
}

export function mountHomeSurface(rootElement: HTMLElement): void {
  installWebviewStyles("home", homeStyles);
  document.title = "Home";
  createRoot(rootElement).render(<HomeSurface />);
}
