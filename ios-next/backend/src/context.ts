import type { Context } from "hono";
import type { AppEnv } from "./env";
import type { Repo } from "./repo/types";

export interface Mail {
  to: string;
  subject: string;
  text: string;
  html: string;
}

/** Outbound mail. Returns false when mail is not configured. */
export type Mailer = (env: AppEnv, mail: Mail) => Promise<boolean>;

/** Injectable dependencies; tests replace them. */
export interface Deps {
  repo: (env: AppEnv) => Repo | null;
  now: () => number;
  fetch: typeof fetch;
  mailer: Mailer;
}

export type Principal = { kind: "user"; userId: string; expiresAt: number; family: string | null } | { kind: "host"; userId: string; hostId: string };

export type HonoEnv = {
  Bindings: AppEnv;
  Variables: {
    deps: Deps;
    repo: Repo;
    principal: Principal;
  };
};

export type Ctx = Context<HonoEnv>;
