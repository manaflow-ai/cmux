import FileFsRef from './file-fs-ref';
/**
 * Run a Python script that only uses the standard library.
 */
export declare function runStdlibPyScript(options: {
    scriptName: string;
    pythonPath?: string;
    args?: string[];
    cwd?: string;
}): Promise<{
    exitCode: number;
    stdout: string;
    stderr: string;
}>;
/**
 * Check if a Python file is a valid entrypoint by detecting:
 * - A top-level 'app' callable (Flask, FastAPI, Sanic, WSGI/ASGI, etc.)
 * - A top-level 'handler' class (BaseHTTPRequestHandler subclass)
 */
export declare function isPythonEntrypoint(file: FileFsRef | {
    fsPath?: string;
}): Promise<boolean>;
