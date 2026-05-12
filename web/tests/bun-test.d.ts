declare module "bun:test" {
  type TestCallback = () => unknown | Promise<unknown>;
  type LifecycleHook = (fn: TestCallback, timeout?: number) => void;
  type TestFunction = {
    (name: string, fn: TestCallback, timeout?: number): void;
    only: TestFunction;
    skip: TestFunction;
    todo: (name: string) => void;
  };
  type MatcherFunction = (...args: unknown[]) => unknown;
  type Matchers = Record<string, MatcherFunction> & {
    not: Matchers;
    rejects: Matchers;
    resolves: Matchers;
  };
  type MockFunction<T extends (...args: unknown[]) => unknown> = T & {
    mockClear: () => void;
    mockResolvedValue: (value: unknown) => void;
  };
  type Mock = {
    <T extends (...args: unknown[]) => unknown>(
      implementation?: T,
    ): MockFunction<T>;
    module: (specifier: string, factory: () => unknown) => void;
  };

  export const afterAll: LifecycleHook;
  export const afterEach: LifecycleHook;
  export const beforeAll: LifecycleHook;
  export const beforeEach: LifecycleHook;
  export const describe: TestFunction;
  export const expect: {
    (actual: unknown): Matchers;
    objectContaining: (value: unknown) => unknown;
  };
  export const mock: Mock;
  export const test: TestFunction;
}
