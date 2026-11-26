// A minimal browser for the analytics consent tests: window events, both
// storages and a cookie jar, enough for app/lib/posthog-client.ts.
export type FakeBrowser = {
  cookies: Map<string, string>;
  local: Map<string, string>;
};

function storage(map: Map<string, string>) {
  const store = {
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, String(value)),
    removeItem: (key: string) => void map.delete(key),
  };
  return new Proxy(store, {
    ownKeys: () => [...map.keys()],
    getOwnPropertyDescriptor: (_target, key) =>
      typeof key === "string" && map.has(key)
        ? { enumerable: true, configurable: true, value: map.get(key) }
        : undefined,
  });
}

export function installFakeBrowser(local: Record<string, string> = {}): FakeBrowser {
  const cookies = new Map<string, string>();
  const localMap = new Map(Object.entries(local));
  const events = new EventTarget();
  const target = globalThis as unknown as Record<string, unknown>;
  target.window = {
    localStorage: storage(localMap),
    sessionStorage: storage(new Map()),
    location: { hostname: "cmux.com" },
    addEventListener: events.addEventListener.bind(events),
    removeEventListener: events.removeEventListener.bind(events),
    dispatchEvent: events.dispatchEvent.bind(events),
  };
  target.document = {
    get cookie() {
      return [...cookies].map(([k, v]) => `${k}=${v}`).join("; ");
    },
    set cookie(value: string) {
      const [pair, ...attributes] = value.split(";");
      const [name, ...rest] = (pair ?? "").split("=");
      const expired = attributes.some((a) => a.trim().toLowerCase().startsWith("expires=thu, 01 jan 1970"));
      if (!name) return;
      if (expired) cookies.delete(name.trim());
      else cookies.set(name.trim(), rest.join("="));
    },
  };
  return { cookies, local: localMap };
}

export function fakePostHog() {
  let optedOut = false;
  const calls: string[] = [];
  const record = (name: string) => (...args: unknown[]) => {
    calls.push(name);
    return args;
  };
  const client = {
    init: record("init"),
    capture: record("capture"),
    identify: record("identify"),
    reset: record("reset"),
    opt_out_capturing: () => {
      calls.push("opt_out_capturing");
      optedOut = true;
    },
    opt_in_capturing: () => {
      calls.push("opt_in_capturing");
      optedOut = false;
    },
    has_opted_out_capturing: () => optedOut,
  };
  return { client, calls };
}
