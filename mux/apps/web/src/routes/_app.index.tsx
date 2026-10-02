import { createFileRoute, redirect } from "@tanstack/react-router";
import { conversationsQuery } from "../chat/queries.ts";

export const Route = createFileRoute("/_app/")({
  // With one conversation (the local mux), open it: Cmd+1 lands in the chat.
  beforeLoad: async ({ context: { queryClient, session } }) => {
    const conversations = await queryClient.ensureQueryData(conversationsQuery(session.source));
    if (conversations.length === 1) {
      throw redirect({
        to: "/c/$conversationId",
        params: { conversationId: conversations[0].id },
        replace: true,
      });
    }
  },
  component: () => <p className="empty">Select a conversation, or start one with ✎.</p>,
});
