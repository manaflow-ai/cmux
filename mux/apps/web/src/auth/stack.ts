// Sign-in against Stack Auth's REST API (cmux accounts). The refresh token is
// kept in localStorage; access tokens live in memory and refresh before expiry.

const STACK_API = "https://api.stack-auth.com/api/v1";
const REFRESH_KEY = "mux.stackRefreshToken";
const DEV_USER_KEY = "mux.devUser";

export interface AuthConfig {
  stackProjectId: string | null;
  stackPublishableClientKey: string | null;
  devAuth: boolean;
}

export type Credential = { kind: "stack"; accessToken: string } | { kind: "dev"; user: string };

function storage(): Storage | undefined {
  try {
    return window.localStorage;
  } catch {
    return undefined;
  }
}

export class StackAuth {
  private config?: AuthConfig;
  private access?: { token: string; expiresAt: number };
  private listeners = new Set<() => void>();

  async load(): Promise<AuthConfig> {
    this.config ??= (await (await fetch("/api/auth/config")).json()) as AuthConfig;
    // `?dev_user=name` signs in as a development identity where the server allows it.
    const devUser = new URL(window.location.href).searchParams.get("dev_user");
    if (devUser && this.config.devAuth) storage()?.setItem(DEV_USER_KEY, devUser);
    return this.config;
  }

  signedIn(): boolean {
    return Boolean(
      storage()?.getItem(REFRESH_KEY) || (this.config?.devAuth && storage()?.getItem(DEV_USER_KEY)),
    );
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  async signIn(email: string, password: string): Promise<void> {
    const response = await fetch(`${STACK_API}/auth/password/sign-in`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({ email, password }),
    });
    const body = (await response.json()) as {
      refresh_token?: string;
      access_token?: string;
      error?: string;
    };
    if (!response.ok || !body.refresh_token || !body.access_token) {
      throw new Error(body.error ?? "Sign-in failed. Check the email and password.");
    }
    storage()?.setItem(REFRESH_KEY, body.refresh_token);
    this.setAccess(body.access_token);
    this.emit();
  }

  signOut(): void {
    storage()?.removeItem(REFRESH_KEY);
    storage()?.removeItem(DEV_USER_KEY);
    this.access = undefined;
    this.emit();
  }

  /** A credential for the next request, refreshing the access token when needed. */
  async credential(): Promise<Credential> {
    const refresh = storage()?.getItem(REFRESH_KEY);
    if (refresh) {
      if (!this.access || this.access.expiresAt - Date.now() < 60_000) await this.refresh(refresh);
      return { kind: "stack", accessToken: this.access!.token };
    }
    const devUser = storage()?.getItem(DEV_USER_KEY);
    if (devUser && this.config?.devAuth) return { kind: "dev", user: devUser };
    throw new Error("not signed in");
  }

  private async refresh(refreshToken: string): Promise<void> {
    const response = await fetch(`${STACK_API}/auth/sessions/current/refresh`, {
      method: "POST",
      headers: { ...this.headers(), "x-stack-refresh-token": refreshToken },
      body: "{}",
    });
    const body = (await response.json()) as { access_token?: string };
    if (!response.ok || !body.access_token) {
      this.signOut();
      throw new Error("Your session ended. Sign in again.");
    }
    this.setAccess(body.access_token);
  }

  private setAccess(token: string): void {
    let expiresAt = Date.now() + 5 * 60_000;
    try {
      const payload = JSON.parse(
        atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")),
      ) as { exp?: number };
      if (typeof payload.exp === "number") expiresAt = payload.exp * 1000;
    } catch {
      // Keep the conservative default.
    }
    this.access = { token, expiresAt };
  }

  private headers(): Record<string, string> {
    if (!this.config?.stackProjectId || !this.config.stackPublishableClientKey) {
      throw new Error("This server has no Stack project configured.");
    }
    return {
      "content-type": "application/json",
      "x-stack-project-id": this.config.stackProjectId,
      "x-stack-publishable-client-key": this.config.stackPublishableClientKey,
      "x-stack-access-type": "client",
    };
  }

  private emit(): void {
    for (const listener of this.listeners) listener();
  }
}
