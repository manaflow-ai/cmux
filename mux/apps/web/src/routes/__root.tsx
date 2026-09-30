import { useSuspenseQuery } from "@tanstack/react-query";
import { createRootRouteWithContext, Link, Outlet } from "@tanstack/react-router";
import { conversationsQuery } from "../chat/queries.ts";
import type { RouterContext } from "../router.tsx";

export const Route = createRootRouteWithContext<RouterContext>()({
  loader: ({ context }) => context.queryClient.ensureQueryData(conversationsQuery(context.source)),
  component: Root,
});

function Root() {
  const { source } = Route.useRouteContext();
  const { data } = useSuspenseQuery(conversationsQuery(source));
  return (
    <div className="app">
      <nav className="list">
        {data.map((c) => (
          <Link
            key={c.id}
            to="/c/$conversationId"
            params={{ conversationId: c.id }}
            className="row"
          >
            <span className="title">{c.title}</span>
            <span className="preview">{c.preview}</span>
          </Link>
        ))}
      </nav>
      <main className="thread">
        <Outlet />
      </main>
    </div>
  );
}
