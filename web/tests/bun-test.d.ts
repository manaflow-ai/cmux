declare module "bun:test" {
  type TestCallback = () => unknown | Promise<unknown>;
  type Lifecycle = (fn: TestCallback, timeout?: number) => void;
  type NamedTest = (name: string, fn: TestCallback, timeout?: number) => void;

  type Matchers = {
    readonly not: Matchers;
    readonly resolves: Matchers;
    readonly rejects: Matchers;
    toBe(expected: unknown): void;
    toBeInstanceOf(expected: unknown): void;
    toBeNull(): void;
    toContain(expected: unknown): void;
    toEqual(expected: unknown): void;
    toHaveBeenCalled(): void;
    toHaveBeenCalledWith(...expected: unknown[]): void;
    toHaveLength(expected: number): void;
    toHaveProperty(key: string): void;
    toMatchObject(expected: unknown): void;
    toStartWith(expected: string): void;
    toThrow(expected?: unknown): void;
  };

  type MockControls = {
    mockClear(): void;
  };

  type MockModule = {
    <T extends (...args: never[]) => unknown>(fn: T): T & MockControls;
    module(moduleName: string, factory: () => unknown): void;
  };

  export const afterAll: Lifecycle;
  export const afterEach: Lifecycle;
  export const beforeAll: Lifecycle;
  export const beforeEach: Lifecycle;
  export const describe: NamedTest;
  export const expect: (actual: unknown) => Matchers;
  export const mock: MockModule;
  export const test: NamedTest;
}
