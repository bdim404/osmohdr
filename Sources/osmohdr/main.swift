import Foundation
import Metal
import CoreImage

enum ToolError: Error, CustomStringConvertible {
    case usage(String)
    case badLUT(String)
    case noVideo(String)
    case reader(String)
    case writer(String)

    var description: String {
        switch self {
        case .usage(let m): return m
        case .badLUT(let p): return "cannot read 3D LUT: \(p)"
        case .noVideo(let p): return "no video track: \(p)"
        case .reader(let m): return "read failed: \(m)"
        case .writer(let m): return "write failed: \(m)"
        }
    }
}

struct Options {
    var inputs: [URL] = []
    var output: URL?
    var lut: URL?
    var beauty: Float = 1
    var smooth: Float = 1
    var whiten: Float = 1
    var bitrate = 80
    var limit: Int?
    var mask = false
    var jobs = 2
    var pannini: Double = 0
    var focal: Double?
}

let usage = """
usage: osmohdr [options] <video or folder>...

  -o, --output DIR    output folder (default: <input folder>/HDR)
  --lut FILE          D-Log M to HLG .cube (default: built-in Mimo match)
  --beauty X          overall beauty strength, 0 disables (default 1)
  --smooth X          skin smoothing multiplier (default 1)
  --whiten X          skin brightening multiplier (default 1)
  --pannini X         wide-angle edge stretch correction strength, 1 = full (default 0, off)
  --focal MM          35mm-equivalent focal length (default: from DJI metadata, else 15)
  --bitrate MBPS      HEVC bitrate (default 80)
  --frames N          only process the first N frames
  --jobs N            videos processed at the same time (default 2)
  --mask              render the beauty mask instead of the image
"""

func parseOptions(_ args: [String]) throws -> Options {
    var o = Options()
    var i = 0
    func value() throws -> String {
        i += 1
        guard i < args.count else { throw ToolError.usage("missing value for \(args[i - 1])\n\n\(usage)") }
        return args[i]
    }
    func number(_ s: String) throws -> Float {
        guard let v = Float(s), v.isFinite, v >= 0 else { throw ToolError.usage("invalid number: \(s)") }
        return v
    }
    func count(_ s: String) throws -> Int {
        let v = try number(s)
        guard v <= 1_000_000_000 else { throw ToolError.usage("invalid number: \(s)") }
        return max(1, Int(v))
    }
    func ranged(_ name: String, _ s: String, _ range: ClosedRange<Float>) throws -> Double {
        let v = try number(s)
        guard range.contains(v) else { throw ToolError.usage("\(name) expects \(Int(range.lowerBound))-\(Int(range.upperBound)), got \(s)") }
        return Double(v)
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "-h", "--help": throw ToolError.usage(usage)
        case "-o", "--output": o.output = URL(fileURLWithPath: try value())
        case "--lut": o.lut = URL(fileURLWithPath: try value())
        case "--beauty": o.beauty = try number(try value())
        case "--smooth": o.smooth = try number(try value())
        case "--whiten": o.whiten = try number(try value())
        case "--pannini": o.pannini = try ranged(a, try value(), 0...10)
        case "--focal": o.focal = try ranged(a, try value(), 1...500)
        case "--bitrate": o.bitrate = try count(try value())
        case "--frames": o.limit = try count(try value())
        case "--mask": o.mask = true
        case "--jobs": o.jobs = try count(try value())
        default:
            if a.hasPrefix("-") { throw ToolError.usage("unknown option \(a)\n\n\(usage)") }
            o.inputs.append(URL(fileURLWithPath: a))
        }
        i += 1
    }
    if o.inputs.isEmpty { throw ToolError.usage(usage) }
    return o
}

func collectVideos(_ urls: [URL]) -> [URL] {
    let exts: Set<String> = ["mp4", "mov"]
    var result: [URL] = []
    let fm = FileManager.default
    for url in urls {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            FileHandle.standardError.write("skip missing \(url.path)\n".data(using: .utf8)!)
            continue
        }
        if isDir.boolValue {
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            result += items.filter { exts.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            result.append(url)
        }
    }
    return result
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    guard let lutURL = options.lut ?? Bundle.module.url(forResource: "mimo_ac6_dlogm_hlg", withExtension: "cube") else {
        throw ToolError.badLUT("built-in LUT missing")
    }
    let lut = try CubeLUT(url: lutURL)
    guard let device = MTLCreateSystemDefaultDevice() else { throw ToolError.usage("no Metal device") }
    func makeContext(_ name: String) -> CIContext {
        CIContext(mtlDevice: device, options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .workingFormat: CIFormat.RGBAf,
            .cacheIntermediates: false,
            .name: name
        ])
    }
    let videos = collectVideos(options.inputs)
    if videos.isEmpty { throw ToolError.usage("no videos found") }
    let jobs = min(options.jobs, videos.count)
    let started = Date()
    func run(_ n: Int) async {
        let video = videos[n]
        let dir = options.output ?? video.deletingLastPathComponent().appendingPathComponent("HDR")
        let out = dir.appendingPathComponent(video.deletingPathExtension().lastPathComponent + "_HDR.mov")
        if out.standardizedFileURL == video.standardizedFileURL { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let measured = options.focal == nil ? DJIMetadata.equivalentFocalLength(of: video) : nil
            let focal = options.focal ?? measured ?? 15
            let lens = options.pannini > 0 ? try Pannini(strength: options.pannini, focalMM: focal) : nil
            let assumed = options.focal == nil && measured == nil ? " assumed" : ""
            let note = lens.map { String(format: "  (%.1f mm%@, pannini %.2g)", $0.focalMM, assumed, $0.d) } ?? ""
            print("[\(n + 1)/\(videos.count)] \(video.lastPathComponent) -> \(out.path)\(note)")
            let beauty = options.beauty > 0 ? try Beauty(context: makeContext("osmohdr.analysis"), smooth: options.beauty * options.smooth, whiten: options.beauty * options.whiten) : nil
            let renderer = Renderer(context: makeContext("osmohdr.render"), lut: lut, lens: lens, beauty: beauty, showMask: options.mask)
            try await convertVideo(input: video, output: out, options: options, renderer: renderer, progress: jobs == 1)
        } catch {
            FileHandle.standardError.write("  failed: \(video.lastPathComponent): \(error)\n".data(using: .utf8)!)
        }
    }
    await withTaskGroup(of: Void.self) { group in
        var next = 0
        while next < jobs {
            let n = next
            group.addTask { await run(n) }
            next += 1
        }
        while await group.next() != nil {
            if next < videos.count {
                let n = next
                group.addTask { await run(n) }
                next += 1
            }
        }
    }
    if videos.count > 1 {
        print(String(format: "all done: %d videos in %.1fs", videos.count, Date().timeIntervalSince(started)))
    }
} catch let e as ToolError {
    FileHandle.standardError.write("\(e)\n".data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
