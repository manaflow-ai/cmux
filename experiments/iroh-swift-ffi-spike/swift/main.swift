// Swift harness for the cmux iroh FFI spike.
//
// listen: bind an endpoint, print its EndpointId + route JSON, echo one
//         connection's bytes back until the peer closes.
// dial:   bind an endpoint, dial a peer by EndpointId (n0 discovery + relays),
//         send a payload, verify the echo round-trips.
//
// Build/run via ../build.sh. This is spike code, not app code; blocking calls
// on the CLI main thread are intentional.

import Foundation

// Line-buffer stdout even when piped, so orchestration scripts can react to
// the endpoint-id line before the process exits.
setvbuf(stdout, nil, _IOLBF, 0)

let errCap = 512

func lastError(_ buf: [CChar]) -> String {
    String(cString: buf, encoding: .utf8) ?? "unknown error"
}

func takeString(_ raw: UnsafeMutablePointer<CChar>?) -> String {
    guard let raw else { return "" }
    defer { cmux_iroh_string_free(raw) }
    return String(cString: raw)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func bindEndpoint(acceptConnections: Bool) -> OpaquePointer {
    var err = [CChar](repeating: 0, count: errCap)
    guard let endpoint = cmux_iroh_endpoint_bind(true, acceptConnections, &err, errCap) else {
        fail("bind: \(lastError(err))")
    }
    return endpoint
}

func waitOnline(_ endpoint: OpaquePointer) {
    var err = [CChar](repeating: 0, count: errCap)
    guard cmux_iroh_endpoint_online(endpoint, 30_000, &err, errCap) == 0 else {
        fail("online: \(lastError(err))")
    }
}

func runListen() {
    print("binding endpoint...")
    let endpoint = bindEndpoint(acceptConnections: true)
    print("bound; waiting for relay connection...")
    waitOnline(endpoint)
    print("endpoint-id: \(takeString(cmux_iroh_endpoint_id(endpoint)))")
    print("route: \(takeString(cmux_iroh_endpoint_route_json(endpoint)))")
    print("listening; dial me with: swift-harness dial <endpoint-id>")

    var err = [CChar](repeating: 0, count: errCap)
    guard let connection = cmux_iroh_endpoint_accept(endpoint, 180_000, &err, errCap) else {
        fail("accept: \(lastError(err))")
    }
    print("accepted connection; echoing")

    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    var total = 0
    while true {
        let read = cmux_iroh_connection_recv(connection, &buf, buf.count, &err, errCap)
        if read < 0 { fail("recv: \(lastError(err))") }
        if read == 0 { break }
        total += read
        guard cmux_iroh_connection_send(connection, buf, read, &err, errCap) == 0 else {
            fail("send: \(lastError(err))")
        }
    }
    print("echoed \(total) byte(s); peer closed stream")
    cmux_iroh_connection_close(connection)
    cmux_iroh_endpoint_close(endpoint)
}

func runDial(endpointID: String, payload: String) {
    let endpoint = bindEndpoint(acceptConnections: false)
    var err = [CChar](repeating: 0, count: errCap)
    let started = Date()
    guard let connection = endpointID.withCString({ id in
        cmux_iroh_endpoint_connect(endpoint, id, nil, nil, 0, 60_000, &err, errCap)
    }) else {
        fail("connect: \(lastError(err))")
    }
    let connectSeconds = Date().timeIntervalSince(started)

    let message = Array(payload.utf8)
    guard cmux_iroh_connection_send(connection, message, message.count, &err, errCap) == 0 else {
        fail("send: \(lastError(err))")
    }

    var echoed = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while echoed.count < message.count {
        let read = cmux_iroh_connection_recv(connection, &buf, buf.count, &err, errCap)
        if read < 0 { fail("recv: \(lastError(err))") }
        if read == 0 { break }
        echoed.append(contentsOf: buf[0..<read])
    }
    cmux_iroh_connection_close(connection)
    cmux_iroh_endpoint_close(endpoint)

    guard echoed == message else {
        fail("echo mismatch: sent \(message.count) byte(s), received \(echoed.count)")
    }
    print(String(format: "PROOF: dialed by EndpointId, %d byte(s) echoed in %.2fs connect", message.count, connectSeconds))
}

let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "" {
case "listen":
    runListen()
case "dial" where arguments.count >= 3:
    let payload = arguments.count >= 4
        ? arguments[3]
        : "hello over iroh from swift @ \(Date().timeIntervalSince1970)"
    runDial(endpointID: arguments[2], payload: payload)
default:
    fail("usage: swift-harness listen | swift-harness dial <endpoint-id> [payload]")
}
