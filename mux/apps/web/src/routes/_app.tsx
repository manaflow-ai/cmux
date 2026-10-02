import { useMutation, useQuery, useQueryClient, useSuspenseQuery } from "@tanstack/react-query";
import { createFileRoute, Link, Outlet, redirect, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { conversationsQuery, machinesQuery, viewerQuery } from "../chat/queries.ts";

export const Route = createFileRoute("/_app")({
  beforeLoad: ({ context }) => {
    if (!context.session.auth.signedIn()) throw redirect({ to: "/sign-in" });
    context.session.watchList();
  },
  loader: ({ context: { queryClient, session } }) =>
    Promise.all([
      queryClient.ensureQueryData(viewerQuery(session.source)),
      queryClient.ensureQueryData(conversationsQuery(session.source)),
    ]),
  component: AppLayout,
});

function AppLayout() {
  const { session } = Route.useRouteContext();
  const { data: viewer } = useSuspenseQuery(viewerQuery(session.source));
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
  const signOut = async () => {
    session.auth.signOut();
    queryClient.clear();
    await navigate({ to: "/sign-in" });
  };
  return (
    // One conversation (the local mux): no list, the chat takes the window.
    <div className={conversations.length <= 1 ? "app single" : "app"}>
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
        <div className="rows">
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
        </div>
        <Machines />
        <footer className="list-footer">
          <span className="muted">{viewer.displayName}</span>
          {session.auth.isLocal ? (
            <span className="muted">this Mac</span>
          ) : (
            <button type="button" className="link-button" onClick={() => void signOut()}>
              Sign out
            </button>
          )}
        </footer>
      </nav>
      <main className="thread">
        <Outlet />
      </main>
    </div>
  );
}

function Machines() {
  const { session } = Route.useRouteContext();
  const { data: machines = [] } = useQuery(machinesQuery(session.source));
  const [command, setCommand] = useState<string>();
  const mint = useMutation({
    mutationFn: () => session.source.mintLinkToken(),
    onSuccess: (token) =>
      setCommand(`mux-link login --server ${window.location.origin} --token ${token} && mux-link`),
  });
  return (
    <section className="machines">
      <div className="machines-header">
        <span className="muted">Machines</span>
        {session.auth.isLocal ? null : (
          <button
            type="button"
            className="link-button"
            disabled={mint.isPending}
            onClick={() => mint.mutate()}
          >
            Connect a Mac
          </button>
        )}
      </div>
      {machines.map((m) => (
        <div key={m.id} className="machine">
          <span
            className={m.online ? "dot online" : "dot"}
            aria-label={m.online ? "online" : "offline"}
          />
          {m.name}
        </div>
      ))}
      {command ? (
        <div className="command">
          <p className="muted">Run on the Mac to connect:</p>
          <code>{command}</code>
          <button
            type="button"
            className="link-button"
            onClick={() => void navigator.clipboard.writeText(command)}
          >
            Copy
          </button>
        </div>
      ) : null}
    </section>
  );
}
