import net from "node:net";
import tls from "node:tls";
import http from "node:http";
import http2 from "node:http2";
import { 
    startPreviewProxy, 
    setPreviewProxyLoggingEnabled, 
    configurePreviewProxyForView, 
    getProxyCredentialsForWebContents 
} from "../apps/client/electron/main/task-run-preview-proxy";
import { CertificateManager } from "../apps/client/electron/main/preview-proxy-certs";

// Set test environment variables
process.env.TEST_CMUX_PROXY_ORIGIN = "https://127.0.0.1:8081";
process.env.TEST_ALLOW_INSECURE_UPSTREAM = "true";

// Mock logger
const logger = {
  log: (...args: any[]) => console.log("[LOG]", ...args),
  warn: (...args: any[]) => console.warn("[WARN]", ...args),
  error: (...args: any[]) => console.error("[ERROR]", ...args),
};

const MOCK_WEB_CONTENTS_ID = 123;

const mockWebContents = {
    id: MOCK_WEB_CONTENTS_ID,
    session: {
        setProxy: async (config: any) => {
            console.log("[MOCK] setProxy called with:", config);
        }
    },
    once: (event: string, listener: Function) => {
        console.log(`[MOCK] once listener added for ${event}`);
    }
};

async function connectToProxy(targetHost: string, targetPort: number, credentials: {username: string, password: string}, proxyPort: number) {
    return new Promise<{ tlsSocket: tls.TLSSocket; socket: net.Socket }>((resolve, reject) => {
        const socket = net.connect(proxyPort, "127.0.0.1");
        socket.setNoDelay(true);

        socket.on("connect", () => {
            console.log("Connected to proxy");
            const auth = Buffer.from(`${credentials.username}:${credentials.password}`).toString("base64");
            const request = `CONNECT ${targetHost}:${targetPort} HTTP/1.1\r\n` +
                            `Host: ${targetHost}:${targetPort}\r\n` +
                            `Proxy-Authorization: Basic ${auth}\r\n` +
                            `\r\n`;
            socket.write(request);
        });

        socket.once("data", (data) => {
            const response = data.toString();
            if (response.includes("200 Connection Established") || response.includes("200 OK")) {
                console.log("\nTunnel established! Starting TLS handshake...");
                
                const certManager = new CertificateManager();
                const caCert = certManager.getCaCert();

                const tlsSocket = tls.connect({
                    socket: socket,
                    rejectUnauthorized: true, 
                    ca: caCert,
                    ALPNProtocols: ["h2", "http/1.1"],
                    servername: targetHost,
                });
                
                tlsSocket.on("secureConnect", () => {
                    resolve({ tlsSocket, socket });
                });

                tlsSocket.on("error", (err: Error) => {
                    console.error("TLS Error:", err);
                    reject(err);
                });
            } else {
                reject(new Error(`Proxy connection failed: ${response}`));
            }
        });

        socket.on("error", (err) => {
            reject(err);
        });
    });
}

async function runTests() {
    console.log("Starting preview proxy test...");
    setPreviewProxyLoggingEnabled(true);
    
    // 1. Start the proxy
    const port = await startPreviewProxy(logger);
    console.log(`Proxy started on port ${port}`);

    // Start dummy upstream server
    const certManager = new CertificateManager();
    const { key, cert } = certManager.getCertDataForHost("localhost");
    
    const dummyServer = http2.createSecureServer({ key, cert });
    let lastSession: http2.Http2Session | undefined;
    dummyServer.on('stream', (stream, headers) => {
        console.log("[Dummy Upstream] Received stream");
        if (lastSession) {
            if (stream.session === lastSession) {
                console.log("[Dummy Upstream] REUSED SESSION!");
            } else {
                console.log("[Dummy Upstream] NEW SESSION (not reused)");
            }
        } else {
            console.log("[Dummy Upstream] First session");
        }
        lastSession = stream.session;

        stream.respond({
            ':status': 200,
            'content-type': 'text/plain',
            'cache-control': 'max-age=3600',
            'etag': '"test-etag"',
        });
        stream.end('Hello from dummy upstream!');
    });
    
    await new Promise<void>(resolve => dummyServer.listen(8081, () => resolve()));
    console.log("Dummy upstream started on port 8081");
    
    process.env.TEST_CMUX_PROXY_ORIGIN = "https://127.0.0.1:8081";
    process.env.TEST_ALLOW_INSECURE_UPSTREAM = "true";

    // 2. Configure a session
    // We use a URL that matches the cmux pattern to ensure a route is derived.
    const initialUrl = "http://cmux-test-base-8080.cmux.local";
    await configurePreviewProxyForView({
        webContents: mockWebContents as any,
        initialUrl,
        logger,
        persistKey: "test-persist-key"
    });

    // 3. Get credentials
    const credentials = getProxyCredentialsForWebContents(MOCK_WEB_CONTENTS_ID);
    if (!credentials) {
        throw new Error("Failed to get credentials for mock web contents");
    }
    console.log("Credentials obtained:", credentials);

    try {
        console.log("\n--- Test 1: HTTPS Connect (MITM) ---");
        const { tlsSocket: tlsSocket1, socket: socket1 } = await connectToProxy("cmux-test-base-8080.cmux.local", 443, credentials, port);
        
        console.log("TLS Handshake successful!");
        const cert = tlsSocket1.getPeerCertificate();
        console.log("Peer Certificate Subject:", cert.subject);
        console.log("ALPN Protocol:", tlsSocket1.alpnProtocol);
        console.log("Cipher:", tlsSocket1.getCipher());
        
        if (tlsSocket1.alpnProtocol === 'h2') {
             console.log("HTTP/2 negotiated!");
        } else {
             console.log("HTTP/1.1 negotiated (or no ALPN)");
        }
        
        tlsSocket1.end();
        socket1.destroy();


        console.log("\n--- Test 2: HTTP/2 Request (MITM) ---");
        const { tlsSocket: tlsSocket2, socket: socket2 } = await connectToProxy("cmux-test-base-8080.cmux.local", 443, credentials, port);
        
        if (tlsSocket2.alpnProtocol !== 'h2') {
            throw new Error("HTTP/2 not negotiated for Test 2");
        }

        await new Promise<void>((resolve, reject) => {
            const session = http2.connect("https://cmux-test-base-8080.cmux.local", {
                createConnection: () => tlsSocket2
            });

            session.on('error', (err) => {
                console.error("HTTP/2 Session Error:", err);
                reject(err);
            });

            let reqCount = 0;
            const makeRequest = () => {
                reqCount++;
                console.log(`Sending HTTP/2 Request ${reqCount}...`);
                const req = session.request({
                    ':path': '/',
                    ':method': 'GET'
                });

                req.on('response', (headers) => {
                    console.log(`HTTP/2 Response ${reqCount} Headers:`, headers);
                    if (headers['cache-control'] !== 'max-age=3600') {
                        reject(new Error(`Missing or incorrect cache-control header. Got: ${headers['cache-control']}`));
                    }
                });

                req.setEncoding('utf8');
                let data = '';
                req.on('data', (chunk) => { data += chunk; });
                req.on('end', () => {
                    console.log(`HTTP/2 Response ${reqCount} Body:`, data);
                    if (reqCount < 2) {
                        // Send second request
                        makeRequest();
                    } else {
                        session.close();
                        socket2.destroy();
                        resolve();
                    }
                });
                req.end();
            };

            makeRequest();
        });

        console.log("\n--- Test 3: IP Address Connect (MITM) ---");
        const { tlsSocket: tlsSocket3, socket: socket3 } = await connectToProxy("127.0.0.1", 8081, credentials, port);
        
        console.log("TLS Handshake successful for IP!");
        const cert3 = tlsSocket3.getPeerCertificate();
        console.log("Peer Certificate Subject:", cert3.subject);
        console.log("Peer Certificate SANs:", cert3.subjectaltname);
        
        if (!cert3.subjectaltname || !cert3.subjectaltname.includes("IP Address:127.0.0.1")) {
             // Node's subjectaltname format: "DNS:example.com, IP Address:1.2.3.4"
             if (!cert3.subjectaltname?.includes("127.0.0.1")) {
                 throw new Error(`Certificate missing IP SAN for 127.0.0.1. Got: ${cert3.subjectaltname}`);
             }
        }
        console.log("Verified IP SAN present.");

        tlsSocket3.end();
        socket3.destroy();

        console.log("\n--- Test 4: Plain HTTP Connect (MITM) ---");
        // Start a plain HTTP server
        const plainServer = http.createServer((req, res) => {
            console.log("[Plain Upstream] Received request:", req.method, req.url);
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end('Hello from plain upstream!');
        });
        await new Promise<void>(resolve => plainServer.listen(8082, () => resolve()));
        console.log("Plain upstream started on port 8082");

        // Manually connect to proxy and establish tunnel without TLS
        const plainSocket = net.connect(port, "127.0.0.1");
        await new Promise<void>((resolve, reject) => {
            plainSocket.once('connect', resolve);
            plainSocket.once('error', reject);
        });
        
        // Send CONNECT
        const auth = Buffer.from(`${credentials.username}:${credentials.password}`).toString("base64");
        const connectReq = `CONNECT 127.0.0.1:8082 HTTP/1.1\r\nHost: 127.0.0.1:8082\r\nProxy-Authorization: Basic ${auth}\r\n\r\n`;
        console.log("Sending CONNECT request:\n" + connectReq);
        plainSocket.write(connectReq);

        // Wait for 200 Connection Established
        await new Promise<void>((resolve, reject) => {
            let buffer = Buffer.alloc(0);
            const onData = (chunk: Buffer) => {
                buffer = Buffer.concat([buffer, chunk]);
                const idx = buffer.indexOf("\r\n\r\n");
                if (idx !== -1) {
                    const header = buffer.subarray(0, idx).toString();
                    console.log("Received CONNECT response header:\n" + header);
                    if (header.includes("200 Connection Established")) {
                        plainSocket.removeListener('data', onData);
                        // Put back any remaining data? Usually none for CONNECT response.
                        const remaining = buffer.subarray(idx + 4);
                        if (remaining.length > 0) {
                            plainSocket.unshift(remaining);
                        }
                        resolve();
                    } else {
                        reject(new Error("Failed to establish tunnel: " + header));
                    }
                }
            };
            plainSocket.on('data', onData);
            plainSocket.on('error', reject);
        });
        console.log("Tunnel established for plain HTTP");

        // Send plain HTTP request in chunks
        plainSocket.write("GET / HTTP/1.1\r\n");
        await new Promise(r => setTimeout(r, 500));
        plainSocket.write("Host: 127.0.0.1:8082\r\nConnection: close\r\n\r\n");
        
        await new Promise<void>((resolve, reject) => {
            let response = ''; // Initialize response outside to accumulate chunks
            plainSocket.on('data', (chunk) => {
                response += chunk.toString();
                console.log("[Client] Received plain response chunk:", chunk.toString());
                // The proxy rewrites the port to 8081 (test:base), so we get the HTTP/2 upstream response
                if (response.includes("Hello from dummy upstream!")) {
                    resolve();
                }
            });
            plainSocket.on('error', reject);
            plainSocket.on('close', () => reject(new Error("Socket closed before response")));
            
            // Timeout
            setTimeout(() => reject(new Error("Timeout waiting for plain response")), 2000);
        });
        console.log("Plain HTTP MITM test passed!");
        
        plainServer.close();
        plainSocket.destroy();

        console.log("\n--- Test 5: WebSocket (Plain & TLS) ---");
        const WebSocket = await import("ws");
        
        // Start a dummy WebSocket server
        const wsServer = new WebSocket.WebSocketServer({ port: 8083 });
        wsServer.on('connection', (ws) => {
            console.log("[WS Server] Client connected");
            ws.on('message', (message) => {
                console.log("[WS Server] Received:", message.toString());
                if (message.toString() === "ping") {
                    ws.send("pong");
                }
            });
        });
        console.log("WebSocket server started on port 8083");

        // Test Plain WebSocket (ws://)
        // Note: We need to manually construct the CONNECT request for plain WS because 'ws' lib doesn't support CONNECT proxies easily with custom headers/auth in the same way
        // But for simplicity, we can try to use the 'ws' client with an agent if possible, or just use our existing tunnel helper.
        // Actually, let's use the 'ws' client with a custom agent that establishes the tunnel first.
        
        // Helper to create a WebSocket connection through the proxy
        async function testWebSocket(protocol: "ws" | "wss", targetHost: string, targetPort: number, creds: {username: string, password: string}) {
            console.log(`Testing ${protocol}://${targetHost}:${targetPort}...`);
            
            // Establish tunnel first
            const proxySocket = net.connect(port, "127.0.0.1");
            await new Promise<void>((resolve, reject) => {
                proxySocket.once('connect', resolve);
                proxySocket.once('error', reject);
            });

            const auth = Buffer.from(`${creds.username}:${creds.password}`).toString("base64");
            const connectReq = `CONNECT ${targetHost}:${targetPort} HTTP/1.1\r\nHost: ${targetHost}:${targetPort}\r\nProxy-Authorization: Basic ${auth}\r\n\r\n`;
            proxySocket.write(connectReq);

            await new Promise<void>((resolve, reject) => {
                let buffer = Buffer.alloc(0);
                const onData = (chunk: Buffer) => {
                    buffer = Buffer.concat([buffer, chunk]);
                    const idx = buffer.indexOf("\r\n\r\n");
                    if (idx !== -1) {
                        const header = buffer.subarray(0, idx).toString();
                        if (header.includes("200 Connection Established")) {
                            proxySocket.removeListener('data', onData);
                            resolve();
                        } else {
                            reject(new Error("Failed to establish tunnel: " + header));
                        }
                    }
                };
                proxySocket.on('data', onData);
                proxySocket.on('error', reject);
            });

            // Now we have a raw socket to the upstream (or MITM). 
            // For WSS, we need to upgrade to TLS. For WS, it's just the raw socket.
            let socket = proxySocket;
            if (protocol === "wss") {
                socket = tls.connect({
                    socket: proxySocket,
                    rejectUnauthorized: false,
                    servername: targetHost
                });
                await new Promise<void>((resolve) => socket.once('secureConnect', resolve));
            }

            // Manual handshake to verify proxy
            const handshake = `GET / HTTP/1.1\r\nHost: ${targetHost}:${targetPort}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n`;
            console.log(`[Client] Writing handshake: ${handshake.length} bytes`);
            socket.write(handshake, (err) => {
                if (err) console.error(`[Client] Write error:`, err);
                else console.log(`[Client] Write success`);
            });

            await new Promise<void>((resolve, reject) => {
                const onData = (chunk: Buffer) => {
                    const str = chunk.toString();
                    // console.log(`[Client] Received from proxy:`, str);
                    if (str.includes("101 Switching Protocols")) {
                        socket.removeListener('data', onData);
                        resolve();
                    }
                };
                socket.on('data', onData);
                socket.on('error', reject);
                socket.on('close', () => console.log("[Client] Socket closed"));
                socket.resume();
                setTimeout(() => reject(new Error(`${protocol} handshake timeout`)), 2000);
            });
            
            console.log(`${protocol} handshake successful!`);
            
            socket.destroy();
            console.log(`${protocol} test passed!`);
        }

        try {
            const testHost = "cmux-test-ws-8083.cmux.local";
            
            // Configure proxy for WS test route
            await configurePreviewProxyForView({
                webContents: mockWebContents as any,
                initialUrl: `ws://${testHost}`,
                persistKey: "test:ws",
                logger
            });
            const wsCredentials = getProxyCredentialsForWebContents(MOCK_WEB_CONTENTS_ID);
            if (!wsCredentials) throw new Error("No credentials for test:ws");
            
            // Test Plain WS
            await testWebSocket("ws", testHost, 8083, wsCredentials);
            
            // Test WSS (TLS)
            // Note: The proxy terminates TLS and forwards to plain WS (8083) because our route maps to http://127.0.0.1:8083
            await testWebSocket("wss", testHost, 8083, wsCredentials);
            
        } finally {
            wsServer.close();
        }

        console.log("\nTests completed.");
        process.exit(0);
    } catch (err) {
        console.error("\nTest failed:", err);
        process.exit(1);
    } finally {
        process.exit(0);
    }
}

runTests().catch(err => {
    console.error("Test failed:", err);
    process.exit(1);
});
