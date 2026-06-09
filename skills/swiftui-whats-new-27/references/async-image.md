# AsyncImage
**SDK Version:** 27.0 and later

`AsyncImage` loads an image from a URL and displays it as it arrives. In the 2027 OS releases it applies standard HTTP caching by default: responses are cached according to the server's cache headers, so an image that already loaded can be served from the cache instead of downloaded again, with no code change and no API to enable. Two new entry points add control on top of that default: an initializer that takes a `URLRequest` in place of a `URL` (to set the cache policy or any other request property per image), and the `asyncImageURLSession(_:)` modifier (to supply a `URLSession` with its own `URLCache`).

If the user's deployment target is below iOS 27 / macOS 27 / watchOS 27 / tvOS 27 / visionOS 27, the new `AsyncImage(request:)` initializers and the `asyncImageURLSession(_:)` modifier require availability gating. The default HTTP caching described in the next section is different: it is runtime behavior, not an API call, and applies whenever the app runs on a 2027 OS release regardless of the build SDK or deployment target. A generic "I want caching" ask on a deployment target below SDK 27 needs no code change; the existing `AsyncImage(url:)` already gets the cache on iOS 27+ devices.

## Default HTTP caching

HTTP caching applies to every `AsyncImage` automatically; no API call turns it on, and the cache honors the response's cache headers. Existing `AsyncImage(url:)` code keeps working and gains the cache without modification. The cache lives in the framework's image loader and is not gated on the app's build SDK, so an app gets it when running on the 2027 OS releases even if it was built against an earlier SDK; only the customization below requires the 27 SDK.

```swift
AsyncImage(url: imageURL)   // cached per the server's headers; no change required
```

**Availability:** iOS 27, macOS 27, watchOS 27, tvOS 27, visionOS 27.

## Per-request control with URLRequest

The new `init(request:)` initializers take a `URLRequest` instead of a `URL`, so you set the request's `cachePolicy` (or any other property) yourself. The remaining labels match the `URL` initializers: `scale:` (default `1`), and either a `content:`/`placeholder:` pair or a `transaction:` plus a single `content:` closure that receives an `AsyncImagePhase`. The bare `AsyncImage(request:)` with no closures renders the loaded image directly, like `AsyncImage(url:)`.

```swift
AsyncImage(request: URLRequest(url: imageURL, cachePolicy: .returnCacheDataElseLoad)) { image in
    image.resizable().scaledToFit()
} placeholder: {
    ProgressView()
}
// URLRequest.CachePolicy: .returnCacheDataElseLoad, .returnCacheDataDontLoad,
// .reloadIgnoringLocalCacheData, .reloadRevalidatingCacheData, .useProtocolCachePolicy
```

**Availability:** iOS 27, macOS 27, watchOS 27, tvOS 27, visionOS 27.

## Custom URLSession

`asyncImageURLSession(_:)` sets the `URLSession` that the `AsyncImage` views in its subtree use to load images. Configure that session's `URLCache` to set the memory and disk capacity the images are cached with.

```swift
struct GalleryView: View {
    private static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                           diskCapacity: 256 * 1024 * 1024)
        return URLSession(configuration: configuration)
    }()

    var body: some View {
        ScrollView {
            LazyVStack {
                ForEach(photos) { photo in
                    AsyncImage(request: URLRequest(url: photo.url, cachePolicy: .returnCacheDataElseLoad))
                }
            }
        }
        .asyncImageURLSession(Self.imageSession)
    }
}
```

**Availability:** iOS 27, macOS 27, watchOS 27, tvOS 27, visionOS 27.

## Availability summary

| API | iOS | macOS | watchOS | tvOS | visionOS |
|---|---|---|---|---|---|
| Default HTTP caching | 27 | 27 | 27 | 27 | 27 |
| `AsyncImage(request:…)` initializers | 27 | 27 | 27 | 27 | 27 |
| `asyncImageURLSession(_:)` | 27 | 27 | 27 | 27 | 27 |
