import { queryOptions } from "@tanstack/react-query";
import type { ChatSource } from "./source.ts";

export const viewerQuery = (source: ChatSource) =>
  queryOptions({ queryKey: ["viewer"], queryFn: () => source.viewer(), staleTime: Infinity });

export const conversationsQuery = (source: ChatSource) =>
  queryOptions({ queryKey: ["conversations"], queryFn: () => source.listConversations() });

export const machinesQuery = (source: ChatSource) =>
  queryOptions({
    queryKey: ["machines"],
    queryFn: () => source.listMachines(),
    refetchInterval: 10_000,
  });
