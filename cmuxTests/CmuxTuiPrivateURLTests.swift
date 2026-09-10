import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct CmuxTuiPrivateURLTests {
    @Test(arguments: [
        ("http://localhost:5173/docs/page?q=one#result", "10.16.4.9", "http://10.16.4.9:5173/docs/page?q=one#result"),
        ("https://127.0.0.1:8443/path", "fd98:deb9:4c94::8", "https://[fd98:deb9:4c94::8]:8443/path"),
        ("https://[::1]:8443/a%20b?q=one%2Ftwo#result", "fd98:deb9:4c94::8", "https://[fd98:deb9:4c94::8]:8443/a%20b?q=one%2Ftwo#result"),
        ("http://[::1]/", "10.16.4.9", "http://10.16.4.9/")
    ])
    func privateBrowserURLPreservesTheVisibleURL(raw: String, address: String, expected: String) {
        #expect(CmuxTuiSurfaceProvider.privateBrowserURL(raw, privateAddress: address) == expected)
    }

    @Test(arguments: ["https://cmux.com", "https://[2001:db8::1]:8443/", "not a URL"])
    func nonLoopbackURLsAreNotRewritten(raw: String) {
        #expect(CmuxTuiSurfaceProvider.privateBrowserURL(raw, privateAddress: "10.0.0.2") == nil)
    }

    @Test func privateDesktopURLKeepsTheNoVNCOptions() {
        #expect(
            CmuxTuiSurfaceProvider.privateDesktopURL(privateAddress: "10.16.4.9")
                == "http://10.16.4.9:6901/vnc.html?path=websockify&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000"
        )
    }
}
