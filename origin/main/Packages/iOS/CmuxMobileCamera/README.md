# CmuxMobileCamera

iOS camera service for cmux mobile QR-code pairing.

It owns the `AVCaptureSession` QR-capture stack that used to be buried inside the
`PairingView.swift` view file. The capture surface is exposed two ways:

- ``CameraAuthorization`` — an `async` seam over `AVCaptureDevice` authorization
  (request + status), so view code never touches the callback API directly.
- ``QRCodeScanStream`` — an `AsyncStream<String>` of decoded QR payloads, fed by
  the internal ``QRCodeCaptureController`` (a `UIViewController` that runs the
  capture session and preview layer). Scanned values can be filtered by an
  injected predicate (cmux pairing only accepts `cmux-ios://` links).

## Testing

`QRCodeScanStream` is constructible without a capture session, so a test can
yield synthetic codes through its continuation and assert the consumed sequence:

```swift
let stream = QRCodeScanStream()
stream.yield("cmux-ios://example")
stream.finish()
var seen: [String] = []
for await code in stream.codes { seen.append(code) }
#expect(seen == ["cmux-ios://example"])
```
