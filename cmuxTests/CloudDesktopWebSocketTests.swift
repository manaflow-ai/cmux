import Foundation
import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A protocol fixture proves HTTP and websockify framing through the actual
/// loopback/SOCKS relay. It does not substitute for a live desktop visual test.
@Suite(.timeLimit(.minutes(1)))
struct CloudDesktopWebSocketTests {
    @Test("The same private relay serves HTML and upgrades websockify with bidirectional RFB input")
    func httpAndWebsockifyShareListener() async throws {
        let keyReceived = CloudLinkFirstValue<Data>()
        let pointerReceived = CloudLinkFirstValue<Data>()
        let frame = Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0x33, 0x66, 0x99, 0])
        let fixture = try CloudLoopbackPortForwardTests.FakeSocksHub { connection in
            let request = try await readHeader(connection)
            if request.hasPrefix("GET /vnc.html?") {
                #expect(request.contains("path=websockify&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000"))
                let html = "<!doctype html><canvas id=screen></canvas><script src=app.js></script>"
                try await connection.sendAll(Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)".utf8))
            } else if request.hasPrefix("GET /app.js ") {
                try await connection.sendAll(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nready".utf8))
            } else {
                #expect(request.hasPrefix("GET /websockify "))
                #expect(request.contains("Upgrade: websocket"))
                try await connection.sendAll(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n".utf8))
                // A raw-encoding 1x1 RFB framebuffer update survives the relay.
                try await connection.sendAll(Data([0x82, UInt8(frame.count)]) + frame)
                keyReceived.resolve(try await readMaskedFrame(connection))
                pointerReceived.resolve(try await readMaskedFrame(connection))
            }
        }
        try await fixture.start()
        defer { fixture.stop() }
        let dialer = CloudLoopbackPortForwardTests.FakeHubDialer(endpoint: fixture.endpoint)
        let forwarder = CloudHubPortForwarder(dialer: dialer)
        let target = CloudPortForwardTarget(host: "10.0.0.7", port: 6901)
        let forward = try await forwarder.forward(machineID: "desktop", to: target)
        let port = await forward.localPort
        let url = URL(string: "http://127.0.0.1:\(port)/vnc.html?path=websockify&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (html, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: html, as: UTF8.self).contains("canvas"))
        let (asset, assetResponse) = try await session.data(from: URL(string: "app.js", relativeTo: url)!)
        #expect((assetResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: asset, as: UTF8.self) == "ready")

        let websocket = try await CloudLoopbackPortForwardTests.client(port: port)
        defer { websocket.cancel() }
        try await websocket.sendAll(Data("GET /websockify HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".utf8))
        let upgrade = try await readHeader(websocket)
        #expect(upgrade.hasPrefix("HTTP/1.1 101 "))
        #expect(upgrade.contains("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
        #expect(Data(try await websocket.receiveExactly(2)) == Data([0x82, UInt8(frame.count)]))
        #expect(Data(try await websocket.receiveExactly(frame.count)) == frame)
        let key = Data([4, 1, 0, 0, 0, 0, 0, 97]) // RFB key-down: a
        let pointer = Data([5, 1, 0, 16, 0, 9]) // RFB left button at (16,9)
        try await websocket.sendAll(maskedFrame(key))
        try await websocket.sendAll(maskedFrame(pointer))
        #expect(await keyReceived.result == key)
        #expect(await pointerReceived.result == pointer)
        #expect(fixture.connectTargets == [target, target, target])
        #expect(await forwarder.count == 1)
        await forwarder.closeAll()
        #expect(await forwarder.count == 0)
    }

    @MainActor
    @Test("Changing a model target retargets its existing listener without leaking one")
    func retargetKeepsOneListener() async throws {
        let hub = try CloudLoopbackPortForwardTests.FakeSocksHub()
        try await hub.start()
        defer { hub.stop() }
        let forwarder = CloudHubPortForwarder(dialer: CloudLoopbackPortForwardTests.FakeHubDialer(endpoint: hub.endpoint))
        let model = CloudPortAccessModel(
            target: .init(host: "10.0.0.7", port: 6901), coordinator: nil, wake: {},
            startForward: { target in
                let forward = try await forwarder.forward(machineID: "desktop", to: target)
                return await forward.localPort
            }, stopForward: { await forwarder.closeAll() }, route: .loopback
        )
        model.connect()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !model.isReady, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.isReady)
        let originalPort = try #require(await forwarder.localPort(machineID: "desktop", port: 6901))
        let next = CloudPortForwardTarget(host: "10.0.0.9", port: 6901)
        model.updateTarget(next)
        while !model.isReady, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.isReady)
        #expect(await forwarder.count == 1)
        #expect(await forwarder.localPort(machineID: "desktop", port: 6901) == originalPort)
        let connection = try await CloudLoopbackPortForwardTests.client(port: originalPort)
        defer { connection.cancel() }
        try await connection.sendAll(Data([7]))
        #expect(Data(try await connection.receiveExactly(1)) == Data([7]))
        #expect(hub.connectTargets == [next])
        await model.retire()
        #expect(await forwarder.count == 0)
    }

    private func readHeader(_ connection: NWConnection) async throws -> String {
        var data = Data()
        while data.count < 16_384 {
            data.append(contentsOf: try await connection.receiveExactly(1))
            if data.suffix(4) == Data([13, 10, 13, 10]) { return String(decoding: data, as: UTF8.self) }
        }
        throw FixtureError.headerTooLarge
    }

    private func maskedFrame(_ payload: Data) -> Data {
        let mask: [UInt8] = [1, 2, 3, 4]
        return Data([0x82, 0x80 | UInt8(payload.count)]) + Data(mask)
            + Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
    }

    private func readMaskedFrame(_ connection: NWConnection) async throws -> Data {
        let header = try await connection.receiveExactly(2)
        guard header[0] == 0x82, header[1] & 0x80 != 0 else { throw FixtureError.invalidFrame }
        let count = Int(header[1] & 0x7f)
        let mask = try await connection.receiveExactly(4)
        let payload = try await connection.receiveExactly(count)
        return Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
    }

    private enum FixtureError: Error { case headerTooLarge, invalidFrame }
}
