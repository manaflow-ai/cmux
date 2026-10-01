import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/_app/")({
  component: () => <p className="empty">Select a conversation, or start one with ✎.</p>,
});
