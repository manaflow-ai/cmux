import { useMutation, useQueryClient, useSuspenseQuery } from "@tanstack/react-query";
import { createRootRouteWithContext, Link, Outlet, useNavigate } from "@tanstack/react-router";
import { conversationsQuery, viewerQuery } from "../chat/queries.ts";
import type { RouterContext } from "../router.tsx";

export const Route = createRootRouteWithContext<RouterContext>()({
  loader: ({ context: { queryClient, session } }) =>
    Promise.all([
      queryClient.ensureQueryData(viewerQuery(session.source)),
      queryClient.ensureQueryData(conversationsQuery(session.source)),
    ]),
  component: Root,
});

function Root() {
  const { session } = Route.useRouteContext();
  const { data: conversations } = useSuspenseQuery(conversationsQuery(session.source));
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const create = useMutation({
    mutationFn: () => session.source.createConversation({}),
    onSuccess: async (conversation) => {
      await queryClient.invalidateQueries({ queryKey: ["conversations"] });
      await navigate({ to: "/c/$conversationId", params: { conversationId: conversation.id } });
    },
  });
  return (
    <div className="app">
      <nav className="list">
        <header className="list-header">
          <span className="list-title">Messages</span>
          <button
            type="button"
            className="compose-button"
            aria-label="New conversation"
            disabled={create.isPending}
            onClick={() => create.mutate()}
          >
            ✎
          </button>
        </header>
        {conversations.map((c) => (
          <Link
            key={c.id}
            to="/c/$conversationId"
            params={{ conversationId: c.id }}
            className="row"
          >
            <span className="title">{c.title}</span>
            <span className="preview">{c.preview || "No messages yet"}</span>
          </Link>
        ))}
      </nav>
      <main className="thread">
        <Outlet />
      </main>
    </div>
  );
}
