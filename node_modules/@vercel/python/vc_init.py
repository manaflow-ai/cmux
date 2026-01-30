from __future__ import annotations
import sys
import os
import site
import importlib
import base64
import json
import inspect
import asyncio
import http
import time
import traceback
from importlib import util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import socket
import functools
import logging
import builtins
from typing import Callable, Literal, TextIO
import contextvars
import contextlib
import atexit


_here = os.path.dirname(__file__)
_vendor_rel = '__VC_HANDLER_VENDOR_DIR'
_vendor = os.path.normpath(os.path.join(_here, _vendor_rel))

if os.path.isdir(_vendor):
    # Process .pth files like a real site-packages dir
    site.addsitedir(_vendor)

    # Move _vendor to the front (after script dir if present)
    try:
        while _vendor in sys.path:
            sys.path.remove(_vendor)
    except ValueError:
        pass

    # Put vendored deps ahead of site-packages but after the script dir
    idx = 1 if (sys.path and sys.path[0] in ('', _here)) else 0
    sys.path.insert(idx, _vendor)

    importlib.invalidate_caches()


def setup_logging(send_message: Callable[[dict], None], storage: contextvars.ContextVar[dict | None]):
    # Override logging.Handler to send logs to the platform when a request context is available.
    class VCLogHandler(logging.Handler):
        def emit(self, record: logging.LogRecord):
            try:
                message = record.getMessage()
            except Exception:
                message = repr(getattr(record, "msg", ""))

            with contextlib.suppress(Exception):
                if record.exc_info:
                    # logging allows exc_info=True or a (type, value, tb) tuple
                    exc_info = record.exc_info
                    if exc_info is True:
                        exc_info = sys.exc_info()
                    if isinstance(exc_info, tuple):
                        tb = ''.join(traceback.format_exception(*exc_info))
                        if tb:
                            if message:
                                message = f"{message}\n{tb}"
                            else:
                                message = tb

            if record.levelno >= logging.CRITICAL:
                level = "fatal"
            elif record.levelno >= logging.ERROR:
                level = "error"
            elif record.levelno >= logging.WARNING:
                level = "warn"
            elif record.levelno >= logging.INFO:
                level = "info"
            else:
                level = "debug"

            context = storage.get()
            if context is not None:
                send_message({
                    "type": "log",
                    "payload": {
                        "context": {
                            "invocationId": context['invocationId'],
                            "requestId": context['requestId'],
                        },
                        "message": base64.b64encode(message.encode()).decode(),
                        "level": level,
                    }
                })
            else:
                # If IPC is not ready, enqueue the message to be sent later.
                enqueue_or_send_message({
                    "type": "log",
                    "payload": {
                        "context": {"invocationId": "0", "requestId": 0},
                        "message": base64.b64encode(message.encode()).decode(),
                        "level": level,
                    }
                })

    # Override sys.stdout and sys.stderr to map logs to the correct request
    class StreamWrapper:
        def __init__(self, stream: TextIO, stream_name: Literal["stdout", "stderr"]):
            self.stream = stream
            self.stream_name = stream_name

        def write(self, message: str):
            context = storage.get()
            if context is not None:
                send_message({
                    "type": "log",
                    "payload": {
                        "context": {
                            "invocationId": context['invocationId'],
                            "requestId": context['requestId'],
                        },
                        "message": base64.b64encode(message.encode()).decode(),
                        "stream": self.stream_name,
                    }
                })
            else:
                enqueue_or_send_message({
                    "type": "log",
                    "payload": {
                        "context": {"invocationId": "0", "requestId": 0},
                        "message": base64.b64encode(message.encode()).decode(),
                        "stream": self.stream_name,
                    }
                })

        def __getattr__(self, name):
            return getattr(self.stream, name)

    sys.stdout = StreamWrapper(sys.stdout, "stdout")
    sys.stderr = StreamWrapper(sys.stderr, "stderr")

    logging.basicConfig(level=logging.INFO, handlers=[VCLogHandler()], force=True)

    # Ensure built-in print funnels through stdout wrapper so prints are
    # attributed to the current request context.
    def print_wrapper(func: Callable[..., None]) -> Callable[..., None]:
        @functools.wraps(func)
        def wrapper(*args, sep=' ', end='\n', file=None, flush=False):
            if file is None:
                file = sys.stdout
            if file in (sys.stdout, sys.stderr):
                file.write(sep.join(map(str, args)) + end)
                if flush:
                    file.flush()
            else:
                # User specified a different file, use original print behavior
                func(*args, sep=sep, end=end, file=file, flush=flush)
        return wrapper

    builtins.print = print_wrapper(builtins.print)


def _stderr(message: str):
    with contextlib.suppress(Exception):
        _original_stderr.write(message + "\n")
        _original_stderr.flush()


# If running in the platform (IPC present), logging must be setup before importing user code so that
# logs happening outside the request context are emitted correctly.
ipc_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
storage: contextvars.ContextVar[dict | None] = contextvars.ContextVar('storage', default=None)
send_message = lambda m: None
_original_stderr = sys.stderr


# Buffer for pre-handshake logs (to avoid blocking IPC on startup)
_ipc_ready = False
_init_log_buf: list[dict] = []
_INIT_LOG_BUF_MAX_BYTES = 1_000_000
_init_log_buf_bytes = 0


def enqueue_or_send_message(msg: dict):
    global _init_log_buf_bytes
    if _ipc_ready:
        send_message(msg)
        return

    enc_len = len(json.dumps(msg))

    if _init_log_buf_bytes + enc_len <= _INIT_LOG_BUF_MAX_BYTES:
        _init_log_buf.append(msg)
        _init_log_buf_bytes += enc_len
    else:
        # Fallback so message is not lost if buffer is full
        with contextlib.suppress(Exception):
            payload = msg.get("payload", {})
            decoded = base64.b64decode(payload.get("message", "")).decode(errors="ignore")
            _original_stderr.write(decoded + "\n")


def flush_init_log_buf_to_stderr():
    global _init_log_buf, _init_log_buf_bytes
    try:
        combined: list[str] = []
        for m in _init_log_buf:
            payload = m.get("payload", {})
            msg = payload.get("message")
            if not msg:
                continue
            with contextlib.suppress(Exception):
                decoded = base64.b64decode(msg).decode(errors="ignore")
                combined.append(decoded)
        if combined:
            _stderr("".join(combined))
    except Exception:
        pass
    finally:
        _init_log_buf.clear()
        _init_log_buf_bytes = 0


atexit.register(flush_init_log_buf_to_stderr)


if 'VERCEL_IPC_PATH' in os.environ:
    with contextlib.suppress(Exception):
        ipc_sock.connect(os.getenv("VERCEL_IPC_PATH", ""))

        def send_message(message: dict):
            with contextlib.suppress(Exception):
                ipc_sock.sendall((json.dumps(message) + '\0').encode())

        setup_logging(send_message, storage)


# Import relative path https://docs.python.org/3/library/importlib.html#importing-a-source-file-directly
try:
    user_mod_path = os.path.join(_here, "__VC_HANDLER_ENTRYPOINT")  # absolute
    __vc_spec = util.spec_from_file_location("__VC_HANDLER_MODULE_NAME", user_mod_path)
    __vc_module = util.module_from_spec(__vc_spec)
    sys.modules["__VC_HANDLER_MODULE_NAME"] = __vc_module
    __vc_spec.loader.exec_module(__vc_module)
    __vc_variables = dir(__vc_module)
except Exception:
    _stderr(f'Error importing __VC_HANDLER_ENTRYPOINT:')
    _stderr(traceback.format_exc())
    exit(1)

_use_legacy_asyncio = sys.version_info < (3, 10)

def format_headers(headers, decode=False):
    keyToList = {}
    for key, value in headers.items():
        if decode and 'decode' in dir(key) and 'decode' in dir(value):
            key = key.decode()
            value = value.decode()
        if key not in keyToList:
            keyToList[key] = []
        keyToList[key].append(value)
    return keyToList


class ASGIMiddleware:
    """
    ASGI middleware that preserves Vercel IPC semantics for request lifecycle:
    - Handles /_vercel/ping
    - Extracts x-vercel-internal-* headers and removes them from downstream app
    - Sets request context into `storage` for logging/metrics
    - Emits handler-started and end IPC messages
    """
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope.get('type') != 'http':
            # Non-HTTP traffic is forwarded verbatim
            await self.app(scope, receive, send)
            return

        if scope.get('path') == '/_vercel/ping':
            await send({
                'type': 'http.response.start',
                'status': 200,
                'headers': [],
            })
            await send({
                'type': 'http.response.body',
                'body': b'',
                'more_body': False,
            })
            return

        # Extract internal headers and set per-request context
        headers_list = scope.get('headers', []) or []
        new_headers = []
        invocation_id = "0"
        request_id = 0

        def _b2s(b: bytes) -> str:
            try:
                return b.decode()
            except Exception:
                return ''

        for k, v in headers_list:
            key = _b2s(k).lower()
            val = _b2s(v)
            if key == 'x-vercel-internal-invocation-id':
                invocation_id = val
                continue
            if key == 'x-vercel-internal-request-id':
                request_id = int(val) if val.isdigit() else 0
                continue
            if key in ('x-vercel-internal-span-id', 'x-vercel-internal-trace-id'):
                continue
            new_headers.append((k, v))

        new_scope = dict(scope)
        new_scope['headers'] = new_headers

        # Announce handler start and set context for logging/metrics
        send_message({
            "type": "handler-started",
            "payload": {
                "handlerStartedAt": int(time.time() * 1000),
                "context": {
                    "invocationId": invocation_id,
                    "requestId": request_id,
                }
            }
        })

        token = storage.set({
            "invocationId": invocation_id,
            "requestId": request_id,
        })

        try:
            await self.app(new_scope, receive, send)
        finally:
            storage.reset(token)
            send_message({
                "type": "end",
                "payload": {
                    "context": {
                        "invocationId": invocation_id,
                        "requestId": request_id,
                    }
                }
            })

if 'VERCEL_IPC_PATH' in os.environ:
    start_time = time.time()

    # Override urlopen from urllib3 (& requests) to send Request Metrics
    try:
        import urllib3
        from urllib.parse import urlparse

        def timed_request(func):
            fetchId = 0
            @functools.wraps(func)
            def wrapper(self, method, url, *args, **kwargs):
                nonlocal fetchId
                fetchId += 1
                start_time = int(time.time() * 1000)
                result = func(self, method, url, *args, **kwargs)
                elapsed_time = int(time.time() * 1000) - start_time
                parsed_url = urlparse(url)
                context = storage.get()
                if context is not None:
                    send_message({
                        "type": "metric",
                        "payload": {
                            "context": {
                                "invocationId": context['invocationId'],
                                "requestId": context['requestId'],
                            },
                            "type": "fetch-metric",
                            "payload": {
                                "pathname": parsed_url.path,
                                "search": parsed_url.query,
                                "start": start_time,
                                "duration": elapsed_time,
                                "host": parsed_url.hostname or self.host,
                                "statusCode": result.status,
                                "method": method,
                                "id": fetchId
                            }
                        }
                    })
                return result
            return wrapper
        urllib3.connectionpool.HTTPConnectionPool.urlopen = timed_request(urllib3.connectionpool.HTTPConnectionPool.urlopen)
    except:
        pass

    class BaseHandler(BaseHTTPRequestHandler):
        # Re-implementation of BaseHTTPRequestHandler's log_message method to
        # log to stdout instead of stderr.
        def log_message(self, format, *args):
            message = format % args
            sys.stdout.write("%s - - [%s] %s\n" %
                             (self.address_string(),
                              self.log_date_time_string(),
                              message.translate(self._control_char_table)))

        # Re-implementation of BaseHTTPRequestHandler's handle_one_request method
        # to send the end message after the response is fully sent.
        def handle_one_request(self):
            self.raw_requestline = self.rfile.readline(65537)
            if not self.raw_requestline:
                self.close_connection = True
                return
            if not self.parse_request():
                return

            if self.path == '/_vercel/ping':
                self.send_response(200)
                self.end_headers()
                return

            invocationId = self.headers.get('x-vercel-internal-invocation-id')
            requestId = int(self.headers.get('x-vercel-internal-request-id'))
            del self.headers['x-vercel-internal-invocation-id']
            del self.headers['x-vercel-internal-request-id']
            del self.headers['x-vercel-internal-span-id']
            del self.headers['x-vercel-internal-trace-id']

            send_message({
                "type": "handler-started",
                "payload": {
                    "handlerStartedAt": int(time.time() * 1000),
                    "context": {
                        "invocationId": invocationId,
                        "requestId": requestId,
                    }
                }
            })

            token = storage.set({
                "invocationId": invocationId,
                "requestId": requestId,
            })

            try:
                self.handle_request()
            finally:
                storage.reset(token)
                send_message({
                    "type": "end",
                    "payload": {
                        "context": {
                            "invocationId": invocationId,
                            "requestId": requestId,
                        }
                    }
                })

    if 'handler' in __vc_variables or 'Handler' in __vc_variables:
        base = __vc_module.handler if ('handler' in __vc_variables) else  __vc_module.Handler
        if not issubclass(base, BaseHTTPRequestHandler):
            _stderr('Handler must inherit from BaseHTTPRequestHandler')
            _stderr('See the docs: https://vercel.com/docs/functions/serverless-functions/runtimes/python')
            exit(1)

        class Handler(BaseHandler, base):
            def handle_request(self):
                mname = 'do_' + self.command
                if not hasattr(self, mname):
                    self.send_error(
                        http.HTTPStatus.NOT_IMPLEMENTED,
                        "Unsupported method (%r)" % self.command)
                    return
                method = getattr(self, mname)
                method()
                self.wfile.flush()
    elif 'app' in __vc_variables:
        if (
            not inspect.iscoroutinefunction(__vc_module.app) and
            not inspect.iscoroutinefunction(__vc_module.app.__call__)
        ):
            from io import BytesIO

            string_types = (str,)
            app = __vc_module.app

            def wsgi_encoding_dance(s, charset="utf-8", errors="replace"):
                if isinstance(s, str):
                    s = s.encode(charset)
                return s.decode("latin1", errors)

            class Handler(BaseHandler):
                def handle_request(self):
                    # Prepare WSGI environment
                    if '?' in self.path:
                        path, query = self.path.split('?', 1)
                    else:
                        path, query = self.path, ''
                    content_length = int(self.headers.get('Content-Length', 0))
                    env = {
                        'CONTENT_LENGTH': str(content_length),
                        'CONTENT_TYPE': self.headers.get('content-type', ''),
                        'PATH_INFO': path,
                        'QUERY_STRING': query,
                        'REMOTE_ADDR': self.headers.get(
                            'x-forwarded-for', self.headers.get(
                                'x-real-ip')),
                        'REQUEST_METHOD': self.command,
                        'SERVER_NAME': self.headers.get('host', 'lambda'),
                        'SERVER_PORT': self.headers.get('x-forwarded-port', '80'),
                        'SERVER_PROTOCOL': 'HTTP/1.1',
                        'wsgi.errors': sys.stderr,
                        'wsgi.input': BytesIO(self.rfile.read(content_length)),
                        'wsgi.multiprocess': False,
                        'wsgi.multithread': False,
                        'wsgi.run_once': False,
                        'wsgi.url_scheme': self.headers.get('x-forwarded-proto', 'http'),
                        'wsgi.version': (1, 0),
                    }
                    for key, value in env.items():
                        if isinstance(value, string_types):
                            env[key] = wsgi_encoding_dance(value)
                    for k, v in self.headers.items():
                        env['HTTP_' + k.replace('-', '_').upper()] = v

                    def start_response(status, headers, exc_info=None):
                        self.send_response(int(status.split(' ')[0]))
                        for name, value in headers:
                            self.send_header(name, value)
                        self.end_headers()
                        return self.wfile.write

                    # Call the application
                    response = app(env, start_response)
                    try:
                        for data in response:
                            if data:
                                self.wfile.write(data)
                                self.wfile.flush()
                    finally:
                        if hasattr(response, 'close'):
                            response.close()
        else:
            # ASGI: Run with Uvicorn so we get proper lifespan and protocol handling
            try:
                import uvicorn
            except Exception:
                _stderr('Uvicorn is required to run ASGI apps. Please ensure it is installed.')
                exit(1)

            # Prefer a callable app.asgi when available; some frameworks expose a boolean here
            user_app_candidate = getattr(__vc_module.app, 'asgi', None)
            user_app = user_app_candidate if callable(user_app_candidate) else __vc_module.app
            asgi_app = ASGIMiddleware(user_app)

            # Pre-bind a socket to obtain an ephemeral port for IPC announcement
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(('127.0.0.1', 0))
            sock.listen(2048)
            http_port = sock.getsockname()[1]

            config = uvicorn.Config(
                app=asgi_app,
                fd=sock.fileno(),
                lifespan='auto',
                access_log=False,
                log_config=None,
                log_level='warning',
            )
            server = uvicorn.Server(config)

            send_message({
                "type": "server-started",
                "payload": {
                    "initDuration": int((time.time() - start_time) * 1000),
                    "httpPort": http_port,
                }
            })

            # Mark IPC as ready and flush any buffered init logs
            _ipc_ready = True
            for m in _init_log_buf:
                send_message(m)
            _init_log_buf.clear()

            # Run the server (blocking)
            server.run()
            # If the server ever returns, exit
            sys.exit(0)

    if 'Handler' in locals():
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        send_message({
            "type": "server-started",
            "payload": {
                "initDuration": int((time.time() - start_time) * 1000),
                "httpPort": server.server_address[1],
            }
        })
        # Mark IPC as ready and flush any buffered init logs
        _ipc_ready = True
        for m in _init_log_buf:
            send_message(m)
        _init_log_buf.clear()
        server.serve_forever()

    _stderr('Missing variable `handler` or `app` in file "__VC_HANDLER_ENTRYPOINT".')
    _stderr('See the docs: https://vercel.com/docs/functions/serverless-functions/runtimes/python')
    exit(1)

if 'handler' in __vc_variables or 'Handler' in __vc_variables:
    base = __vc_module.handler if ('handler' in __vc_variables) else  __vc_module.Handler
    if not issubclass(base, BaseHTTPRequestHandler):
        print('Handler must inherit from BaseHTTPRequestHandler')
        print('See the docs: https://vercel.com/docs/functions/serverless-functions/runtimes/python')
        exit(1)

    print('using HTTP Handler')
    from http.server import HTTPServer
    import http
    import _thread

    server = HTTPServer(('127.0.0.1', 0), base)
    port = server.server_address[1]

    def vc_handler(event, context):
        _thread.start_new_thread(server.handle_request, ())

        payload = json.loads(event['body'])
        path = payload['path']
        headers = payload['headers']
        method = payload['method']
        encoding = payload.get('encoding')
        body = payload.get('body')

        if (
            (body is not None and len(body) > 0) and
            (encoding is not None and encoding == 'base64')
        ):
            body = base64.b64decode(body)

        request_body = body.encode('utf-8') if isinstance(body, str) else body
        conn = http.client.HTTPConnection('127.0.0.1', port)
        try:
            conn.request(method, path, headers=headers, body=request_body)
        except (http.client.HTTPException, socket.error) as ex:
            print ("Request Error: %s" % ex)
        res = conn.getresponse()

        return_dict = {
            'statusCode': res.status,
            'headers': format_headers(res.headers),
        }

        data = res.read()

        try:
            return_dict['body'] = data.decode('utf-8')
        except UnicodeDecodeError:
            return_dict['body'] = base64.b64encode(data).decode('utf-8')
            return_dict['encoding'] = 'base64'

        return return_dict

elif 'app' in __vc_variables:
    if (
        not inspect.iscoroutinefunction(__vc_module.app) and
        not inspect.iscoroutinefunction(__vc_module.app.__call__)
    ):
        print('using Web Server Gateway Interface (WSGI)')
        from io import BytesIO
        from urllib.parse import urlparse
        from werkzeug.datastructures import Headers
        from werkzeug.wrappers import Response

        string_types = (str,)

        def to_bytes(x, charset=sys.getdefaultencoding(), errors="strict"):
            if x is None:
                return None
            if isinstance(x, (bytes, bytearray, memoryview)):
                return bytes(x)
            if isinstance(x, str):
                return x.encode(charset, errors)
            raise TypeError("Expected bytes")

        def wsgi_encoding_dance(s, charset="utf-8", errors="replace"):
            if isinstance(s, str):
                s = s.encode(charset)
            return s.decode("latin1", errors)

        def vc_handler(event, context):
            payload = json.loads(event['body'])

            headers = Headers(payload.get('headers', {}))

            body = payload.get('body', '')
            if body != '':
                if payload.get('encoding') == 'base64':
                    body = base64.b64decode(body)
            if isinstance(body, string_types):
                body = to_bytes(body, charset='utf-8')

            url = urlparse(payload['path'])
            query = url.query
            path = url.path

            environ = {
                'CONTENT_LENGTH': str(len(body)),
                'CONTENT_TYPE': headers.get('content-type', ''),
                'PATH_INFO': path,
                'QUERY_STRING': query,
                'REMOTE_ADDR': headers.get(
                    'x-forwarded-for', headers.get(
                        'x-real-ip', payload.get(
                            'true-client-ip', ''))),
                'REQUEST_METHOD': payload['method'],
                'SERVER_NAME': headers.get('host', 'lambda'),
                'SERVER_PORT': headers.get('x-forwarded-port', '80'),
                'SERVER_PROTOCOL': 'HTTP/1.1',
                'event': event,
                'context': context,
                'wsgi.errors': sys.stderr,
                'wsgi.input': BytesIO(body),
                'wsgi.multiprocess': False,
                'wsgi.multithread': False,
                'wsgi.run_once': False,
                'wsgi.url_scheme': headers.get('x-forwarded-proto', 'http'),
                'wsgi.version': (1, 0),
            }

            for key, value in environ.items():
                if isinstance(value, string_types):
                    environ[key] = wsgi_encoding_dance(value)

            for key, value in headers.items():
                key = 'HTTP_' + key.upper().replace('-', '_')
                if key not in ('HTTP_CONTENT_TYPE', 'HTTP_CONTENT_LENGTH'):
                    environ[key] = value

            response = Response.from_app(__vc_module.app, environ)

            return_dict = {
                'statusCode': response.status_code,
                'headers': format_headers(response.headers)
            }

            if response.data:
                return_dict['body'] = base64.b64encode(response.data).decode('utf-8')
                return_dict['encoding'] = 'base64'

            return return_dict
    else:
        print('using Asynchronous Server Gateway Interface (ASGI)')
        # Originally authored by Jordan Eremieff and included under MIT license:
        # https://github.com/erm/mangum/blob/b4d21c8f5e304a3e17b88bc9fa345106acc50ad7/mangum/__init__.py
        # https://github.com/erm/mangum/blob/b4d21c8f5e304a3e17b88bc9fa345106acc50ad7/LICENSE
        import asyncio
        import enum
        from urllib.parse import urlparse
        from werkzeug.datastructures import Headers


        class ASGICycleState(enum.Enum):
            REQUEST = enum.auto()
            RESPONSE = enum.auto()


        class ASGICycle:
            def __init__(self, scope):
                self.scope = scope
                self.body = b''
                self.state = ASGICycleState.REQUEST
                self.app_queue = None
                self.response = {}

            def __call__(self, app, body):
                """
                Receives the application and any body included in the request, then builds the
                ASGI instance using the connection scope.
                Runs until the response is completely read from the application.
                """
                if _use_legacy_asyncio:
                    loop = asyncio.new_event_loop()
                    self.app_queue = asyncio.Queue(loop=loop)
                else:
                    self.app_queue = asyncio.Queue()
                self.put_message({'type': 'http.request', 'body': body, 'more_body': False})

                asgi_instance = app(self.scope, self.receive, self.send)

                if _use_legacy_asyncio:
                    asgi_task = loop.create_task(asgi_instance)
                    loop.run_until_complete(asgi_task)
                else:
                    asyncio.run(self.run_asgi_instance(asgi_instance))
                return self.response

            async def run_asgi_instance(self, asgi_instance):
                await asgi_instance

            def put_message(self, message):
                self.app_queue.put_nowait(message)

            async def receive(self):
                """
                Awaited by the application to receive messages in the queue.
                """
                message = await self.app_queue.get()
                return message

            async def send(self, message):
                """
                Awaited by the application to send messages to the current cycle instance.
                """
                message_type = message['type']

                if self.state is ASGICycleState.REQUEST:
                    if message_type != 'http.response.start':
                        raise RuntimeError(
                            f"Expected 'http.response.start', received: {message_type}"
                        )

                    status_code = message['status']
                    raw_headers = message.get('headers', [])

                    # Headers from werkzeug transform bytes header value
                    # from b'value' to "b'value'" so we need to process
                    # ASGI headers manually
                    decoded_headers = []
                    for key, value in raw_headers:
                        decoded_key = key.decode() if isinstance(key, bytes) else key
                        decoded_value = value.decode() if isinstance(value, bytes) else value
                        decoded_headers.append((decoded_key, decoded_value))

                    headers = Headers(decoded_headers)

                    self.on_request(headers, status_code)
                    self.state = ASGICycleState.RESPONSE

                elif self.state is ASGICycleState.RESPONSE:
                    if message_type != 'http.response.body':
                        raise RuntimeError(
                            f"Expected 'http.response.body', received: {message_type}"
                        )

                    body = message.get('body', b'')
                    more_body = message.get('more_body', False)

                    # The body must be completely read before returning the response.
                    self.body += body

                    if not more_body:
                        self.on_response()
                        self.put_message({'type': 'http.disconnect'})

            def on_request(self, headers, status_code):
                self.response['statusCode'] = status_code
                self.response['headers'] = format_headers(headers, decode=True)

            def on_response(self):
                if self.body:
                    self.response['body'] = base64.b64encode(self.body).decode('utf-8')
                    self.response['encoding'] = 'base64'

        def vc_handler(event, context):
            payload = json.loads(event['body'])

            headers = payload.get('headers', {})

            body = payload.get('body', b'')
            if payload.get('encoding') == 'base64':
                body = base64.b64decode(body)
            elif not isinstance(body, bytes):
                body = body.encode()

            url = urlparse(payload['path'])
            query = url.query.encode()
            path = url.path

            headers_encoded = []
            for k, v in headers.items():
                # Cope with repeated headers in the encoding.
                if isinstance(v, list):
                    headers_encoded.append([k.lower().encode(), [i.encode() for i in v]])
                else:
                    headers_encoded.append([k.lower().encode(), v.encode()])

            scope = {
                'server': (headers.get('host', 'lambda'), headers.get('x-forwarded-port', 80)),
                'client': (headers.get(
                    'x-forwarded-for', headers.get(
                        'x-real-ip', payload.get(
                            'true-client-ip', ''))), 0),
                'scheme': headers.get('x-forwarded-proto', 'http'),
                'root_path': '',
                'query_string': query,
                'headers': headers_encoded,
                'type': 'http',
                'http_version': '1.1',
                'method': payload['method'],
                'path': path,
                'raw_path': path.encode(),
            }

            asgi_cycle = ASGICycle(scope)
            response = asgi_cycle(__vc_module.app, body)
            return response

else:
    print('Missing variable `handler` or `app` in file "__VC_HANDLER_ENTRYPOINT".')
    print('See the docs: https://vercel.com/docs/functions/serverless-functions/runtimes/python')
    exit(1)
