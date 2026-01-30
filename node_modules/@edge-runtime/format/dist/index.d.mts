interface FormatterOptions {
    formatError?: (error: Error) => string;
    customInspectSymbol?: symbol;
}
declare function createFormat(opts?: FormatterOptions): (...args: unknown[]) => string;

export { createFormat };
