// Renders stills of the living wallpapers (BackdropShader) with real Metal, for a pull request's
// previews. Usage: swift living-wallpaper-stills.swift SOURCE.metal OUT_DIR WIDTH HEIGHT name:seconds[,seconds...]...
// Each shader is drawn light and dark at each time to OUT_DIR/<name>-<light|dark>-<seconds>.png
// with the pointer far away and no clicks, as a window shows it at rest.
import Foundation
import Metal
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 6 else { FileHandle.standardError.write(Data("usage: SOURCE OUT W H name:t,...\n".utf8)); exit(2) }
let source = try String(contentsOfFile: args[1], encoding: .utf8)
let outDir = args[2]
let width = Int(args[3])!, height = Int(args[4])!
let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(source: source, options: nil)
let queue = device.makeCommandQueue()!
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for spec in args[5...] {
    let parts = spec.split(separator: ":")
    let name = String(parts[0])
    let times = parts[1].split(separator: ",").map { Float($0)! }
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: "wp_vertex")
    desc.fragmentFunction = library.makeFunction(name: "wp_" + name)
    desc.colorAttachments[0].pixelFormat = .bgra8Unorm
    let pipeline = try device.makeRenderPipelineState(descriptor: desc)
    for dark in [Float(0), Float(1)] {
        for time in times {
            var u = [Float](repeating: 0, count: 24)
            u[0] = Float(width); u[1] = Float(height)
            u[2] = -10000; u[3] = -10000
            u[4] = time; u[6] = dark
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            td.usage = [.renderTarget]; td.storageMode = .shared
            let tex = device.makeTexture(descriptor: td)!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = tex
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let cb = queue.makeCommandBuffer()!
            let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(u, length: u.count * 4, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: width * height * 4)
            tex.getBytes(&px, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            let provider = CGDataProvider(data: Data(px) as CFData)!
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let url = URL(fileURLWithPath: "\(outDir)/\(name)-\(dark > 0 ? "dark" : "light")-\(Int(time)).png")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
