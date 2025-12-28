/**
 * Type-safe HTTP client for cmux-sandboxd API.
 */

import type {
  AwaitReadyRequest,
  AwaitReadyResponse,
  CreateSandboxRequest,
  ExecRequest,
  ExecResponse,
  HealthResponse,
  PtyCreateSessionRequest,
  PtyResizeRequest,
  PtySession,
  SandboxSummary,
} from "./sandboxd-types.js";

export class SandboxdClientError extends Error {
  constructor(
    message: string,
    public readonly statusCode: number,
    public readonly body?: string
  ) {
    super(message);
    this.name = "SandboxdClientError";
  }
}

/**
 * Type-safe client for cmux-sandboxd HTTP API.
 */
export class SandboxdClient {
  constructor(private readonly baseUrl: string) {
    // Remove trailing slash
    this.baseUrl = baseUrl.replace(/\/$/, "");
  }

  private async request<T>(
    method: string,
    path: string,
    body?: unknown,
    signal?: AbortSignal
  ): Promise<T> {
    const url = `${this.baseUrl}${path}`;
    const headers: Record<string, string> = {};

    let requestBody: BodyInit | undefined;
    if (body !== undefined) {
      if (body instanceof Blob) {
        headers["Content-Type"] = "application/octet-stream";
        requestBody = body;
      } else {
        headers["Content-Type"] = "application/json";
        requestBody = JSON.stringify(body);
      }
    }

    const response = await fetch(url, {
      method,
      headers,
      body: requestBody,
      signal,
    });

    if (!response.ok) {
      const errorBody = await response.text();
      throw new SandboxdClientError(
        `Request failed: ${response.status} ${response.statusText}`,
        response.status,
        errorBody
      );
    }

    // Handle empty responses
    const contentType = response.headers.get("content-type");
    if (!contentType || !contentType.includes("application/json")) {
      return undefined as T;
    }

    return response.json() as Promise<T>;
  }

  // ===========================================================================
  // Health
  // ===========================================================================

  async health(): Promise<HealthResponse> {
    return this.request<HealthResponse>("GET", "/healthz");
  }

  // ===========================================================================
  // Sandbox Management
  // ===========================================================================

  async createSandbox(request: CreateSandboxRequest): Promise<SandboxSummary> {
    return this.request<SandboxSummary>("POST", "/sandboxes", request);
  }

  async listSandboxes(): Promise<SandboxSummary[]> {
    return this.request<SandboxSummary[]>("GET", "/sandboxes");
  }

  async getSandbox(id: string): Promise<SandboxSummary | null> {
    try {
      return await this.request<SandboxSummary>("GET", `/sandboxes/${id}`);
    } catch (error) {
      if (error instanceof SandboxdClientError && error.statusCode === 404) {
        return null;
      }
      throw error;
    }
  }

  async deleteSandbox(id: string): Promise<SandboxSummary | null> {
    try {
      return await this.request<SandboxSummary>("DELETE", `/sandboxes/${id}`);
    } catch (error) {
      if (error instanceof SandboxdClientError && error.statusCode === 404) {
        return null;
      }
      throw error;
    }
  }

  // ===========================================================================
  // Execution
  // ===========================================================================

  async exec(
    sandboxId: string,
    request: ExecRequest,
    signal?: AbortSignal
  ): Promise<ExecResponse> {
    return this.request<ExecResponse>(
      "POST",
      `/sandboxes/${sandboxId}/exec`,
      request,
      signal
    );
  }

  // ===========================================================================
  // File Upload
  // ===========================================================================

  async uploadFiles(
    sandboxId: string,
    tarArchive: Blob | Uint8Array
  ): Promise<void> {
    let blob: Blob;
    if (tarArchive instanceof Blob) {
      blob = tarArchive;
    } else {
      // Copy to a new ArrayBuffer to satisfy TypeScript's BlobPart requirements
      const copy = new Uint8Array(tarArchive);
      blob = new Blob([copy.buffer as ArrayBuffer], { type: "application/octet-stream" });
    }

    await this.request<void>(
      "POST",
      `/sandboxes/${sandboxId}/files`,
      blob
    );
  }

  // ===========================================================================
  // Service Readiness
  // ===========================================================================

  async awaitReady(
    sandboxId: string,
    request: AwaitReadyRequest
  ): Promise<AwaitReadyResponse> {
    return this.request<AwaitReadyResponse>(
      "POST",
      `/sandboxes/${sandboxId}/await-ready`,
      request
    );
  }

  // ===========================================================================
  // PTY Sessions
  // ===========================================================================

  async listPtySessions(sandboxId: string): Promise<PtySession[]> {
    return this.request<PtySession[]>(
      "GET",
      `/sandboxes/${sandboxId}/pty/sessions`
    );
  }

  async createPtySession(
    sandboxId: string,
    request: PtyCreateSessionRequest
  ): Promise<PtySession> {
    return this.request<PtySession>(
      "POST",
      `/sandboxes/${sandboxId}/pty/sessions`,
      request
    );
  }

  async getPtySession(
    sandboxId: string,
    sessionId: string
  ): Promise<PtySession | null> {
    try {
      return await this.request<PtySession>(
        "GET",
        `/sandboxes/${sandboxId}/pty/sessions/${sessionId}`
      );
    } catch (error) {
      if (error instanceof SandboxdClientError && error.statusCode === 404) {
        return null;
      }
      throw error;
    }
  }

  async deletePtySession(sandboxId: string, sessionId: string): Promise<void> {
    await this.request<void>(
      "DELETE",
      `/sandboxes/${sandboxId}/pty/sessions/${sessionId}`
    );
  }

  async resizePtySession(
    sandboxId: string,
    sessionId: string,
    request: PtyResizeRequest
  ): Promise<void> {
    await this.request<void>(
      "POST",
      `/sandboxes/${sandboxId}/pty/sessions/${sessionId}/resize`,
      request
    );
  }

  // ===========================================================================
  // URL Helpers
  // ===========================================================================

  /**
   * Get the subdomain proxy URL for accessing a sandbox's internal port.
   * Format: http://{index}-{port}.{host}
   */
  getSubdomainUrl(sandboxIndex: number, port: number): string {
    const url = new URL(this.baseUrl);
    return `http://${sandboxIndex}-${port}.${url.host}`;
  }
}
