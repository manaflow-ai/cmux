import { isViewer } from "@mux/protocol";
import { useSuspenseQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { conversationQuery } from "../chat/queries.ts";

export const Route = createFileRoute("/c/$conversationId")({
  loader: ({ context, params }) =>
    context.queryClient.ensureQueryData(conversationQuery(context.source, params.conversationId)),
  component: Thread,
});

function Thread() {
  const { conversationId } = Route.useParams();
  const { source } = Route.useRouteContext();
  const { data } = useSuspenseQuery(conversationQuery(source, conversationId));
  const byId = new Map(data.participants.map((p) => [p.id, p]));
  return (
    <ol className="messages">
      {data.messages.map((m) => {
        const sender = byId.get(m.senderId);
        const mine = sender ? isViewer(sender, source.viewerId) : false;
        return (
          <li key={m.id} className={mine ? "bubble mine" : "bubble"}>
            {m.parts.map((p, i) => (p.type === "text" ? <span key={i}>{p.text}</span> : null))}
          </li>
        );
      })}
    </ol>
  );
}
