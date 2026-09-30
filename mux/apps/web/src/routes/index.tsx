import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/")({
  component: () => <p className="empty">Select a conversation.</p>,
});
