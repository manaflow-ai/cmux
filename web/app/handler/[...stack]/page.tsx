import { Suspense } from "react";
import { StackHandler } from "@stackframe/stack";
import { notFound, redirect } from "next/navigation";
import { stackHandlerApp } from "../../lib/stack";
import { signedInForwardTargetForRequest } from "../signed-in-forward";

export default async function StackHandlerPage(props: {
  params: Promise<{ stack: string[] }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  if (!stackHandlerApp) notFound();

  const params = await props.params;
  const searchParams = await props.searchParams;
  const signedInForwardTarget = await signedInForwardTargetForRequest(params.stack, searchParams);
  if (signedInForwardTarget) redirect(signedInForwardTarget);

  return (
    <Suspense>
      <StackHandler fullPage app={stackHandlerApp} params={props.params} />
    </Suspense>
  );
}
