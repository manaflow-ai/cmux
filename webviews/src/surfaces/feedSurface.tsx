import { RouterProvider } from "@tanstack/react-router";
import { createRoot } from "react-dom/client";
import { FeedApp } from "../feed/App";
import { createWebviewsRouter } from "../router";

export function mountFeedSurface(rootElement: HTMLElement): void {
  document.documentElement.dataset.cmuxWebviewKind = "feed";
  document.body.dataset.cmuxWebviewKind = "feed";
  const router = createWebviewsRouter(() => <FeedApp />);
  createRoot(rootElement).render(<RouterProvider router={router} />);
}
