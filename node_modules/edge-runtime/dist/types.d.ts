import type { Colors } from 'picocolors/types';
export interface LoggerOptions {
    color?: keyof Colors;
    withHeader?: boolean;
    withBreakline?: boolean;
}
export interface Logger {
    (message: string, opts?: LoggerOptions): void;
    warn(message: string, opts?: LoggerOptions): void;
    debug(message: string, opts?: LoggerOptions): void;
    error(message: string, opts?: LoggerOptions): void;
    info(message: string, opts?: LoggerOptions): void;
    quotes(str: string): string;
}
export interface NodeHeaders {
    [header: string]: string | string[] | undefined;
}
