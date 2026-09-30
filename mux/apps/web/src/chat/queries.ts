import { queryOptions } from "@tanstack/react-query";
import type { ID } from "@mux/protocol";
import type { ChatSource } from "./source.ts";

export const conversationsQuery = (source: ChatSource) =>
  queryOptions({
    queryKey: ["conversations"],
    queryFn: () => source.listConversations(),
  });

export const conversationQuery = (source: ChatSource, id: ID) =>
  queryOptions({
    queryKey: ["conversation", id],
    queryFn: () => source.getConversation(id),
  });
