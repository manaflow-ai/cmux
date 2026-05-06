import { toNextHandler } from "@rivetkit/next-js";
import { registry } from "../../../../rivet/registry";

export const dynamic = "force-dynamic";
export const maxDuration = 300;

export const { GET, POST, PUT, PATCH, HEAD, OPTIONS } = toNextHandler(registry);

