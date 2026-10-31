import CoreImage
import Foundation

enum DJIMetadata {
    static func equivalentFocalLength(of url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), let moov = topLevelBox("moov", in: handle, end: fileSize) else { return nil }
        for trak in boxes(in: moov) where trak.type == "trak" {
            guard let mdia = child("mdia", of: trak.payload), let hdlr = child("hdlr", of: mdia),
                  hdlr.count > 24, String(decoding: hdlr.dropFirst(24), as: UTF8.self).contains("CAM meta"),
                  let stbl = child("minf", of: mdia).flatMap({ child("stbl", of: $0) }),
                  let offset = firstChunkOffset(stbl), let size = firstSampleSize(stbl), size > 0, size < 1 << 20,
                  offset < fileSize, UInt64(size) <= fileSize - offset, (try? handle.seek(toOffset: offset)) != nil,
                  let sample = try? handle.read(upToCount: Int(size)), sample.count == Int(size),
                  sample.range(of: Data("dvtm_ac206".utf8)) != nil,
                  let rational = message(sample, path: [3, 2, 14, 1]) else { continue }
            let parts = varints(rational)
            guard parts.count == 2, parts[1] > 0 else { continue }
            let focal = Double(parts[0]) / Double(parts[1])
            if focal > 5 && focal < 100 { return focal }
        }
        return nil
    }

    private struct Box { let type: String; let payload: Data }
    private struct Field { let number: Int; let wire: Int; let data: Data }

    private static func topLevelBox(_ type: String, in handle: FileHandle, end: UInt64) -> Data? {
        var offset: UInt64 = 0
        while end - offset >= 8 {
            guard (try? handle.seek(toOffset: offset)) != nil, let header = try? handle.read(upToCount: 16), header.count >= 8 else { return nil }
            var size = UInt64(be32(header, 0))
            var headerSize: UInt64 = 8
            if size == 1 {
                guard header.count >= 16 else { return nil }
                size = be64(header, 8)
                headerSize = 16
            }
            if size == 0 { size = end - offset }
            guard size >= headerSize, size <= end - offset else { return nil }
            if String(decoding: header[4..<8], as: UTF8.self) == type {
                guard size - headerSize <= 256 << 20, (try? handle.seek(toOffset: offset + headerSize)) != nil else { return nil }
                return try? handle.read(upToCount: Int(size - headerSize))
            }
            offset += size
        }
        return nil
    }

    private static func boxes(in data: Data) -> [Box] {
        var result: [Box] = []
        var i = data.startIndex
        while data.endIndex - i >= 8 {
            let available = UInt64(data.endIndex - i)
            var size = UInt64(be32(data, i - data.startIndex))
            var headerSize: UInt64 = 8
            if size == 1 {
                guard available >= 16 else { break }
                size = be64(data, i - data.startIndex + 8)
                headerSize = 16
            }
            if size == 0 { size = available }
            guard size >= headerSize, size <= available else { break }
            let next = i + Int(size)
            result.append(Box(type: String(decoding: data[(i + 4)..<(i + 8)], as: UTF8.self), payload: Data(data[(i + Int(headerSize))..<next])))
            i = next
        }
        return result
    }

    private static func child(_ type: String, of data: Data) -> Data? {
        boxes(in: data).first(where: { $0.type == type })?.payload
    }

    private static func firstChunkOffset(_ stbl: Data) -> UInt64? {
        if let stco = child("stco", of: stbl), stco.count >= 12, be32(stco, 4) > 0 { return UInt64(be32(stco, 8)) }
        if let co64 = child("co64", of: stbl), co64.count >= 16, be32(co64, 4) > 0 { return be64(co64, 8) }
        return nil
    }

    private static func firstSampleSize(_ stbl: Data) -> UInt32? {
        guard let stsz = child("stsz", of: stbl), stsz.count >= 12 else { return nil }
        let uniform = be32(stsz, 4)
        if uniform > 0 { return uniform }
        return stsz.count >= 16 ? be32(stsz, 12) : nil
    }

    private static func be32(_ d: Data, _ o: Int) -> UInt32 {
        let s = d.startIndex + o
        return d[s..<(s + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func be64(_ d: Data, _ o: Int) -> UInt64 {
        let s = d.startIndex + o
        return d[s..<(s + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func varint(_ d: Data, _ i: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while i < d.endIndex, shift < 64 {
            let byte = d[i]
            i += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return value }
            shift += 7
        }
        return nil
    }

    private static func varints(_ d: Data) -> [UInt64] {
        var i = d.startIndex
        var out: [UInt64] = []
        while i < d.endIndex, let v = varint(d, &i) { out.append(v) }
        return out
    }

    private static func fields(_ d: Data) -> [Field] {
        var i = d.startIndex
        var out: [Field] = []
        while i < d.endIndex {
            guard let key = varint(d, &i) else { break }
            let number = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0:
                let start = i
                guard varint(d, &i) != nil else { return out }
                out.append(Field(number: number, wire: wire, data: Data(d[start..<i])))
            case 1:
                guard d.endIndex - i >= 8 else { return out }
                out.append(Field(number: number, wire: wire, data: Data(d[i..<(i + 8)])))
                i += 8
            case 2:
                guard let n = varint(d, &i), n <= UInt64(d.endIndex - i) else { return out }
                let next = i + Int(n)
                out.append(Field(number: number, wire: wire, data: Data(d[i..<next])))
                i = next
            case 5:
                guard d.endIndex - i >= 4 else { return out }
                out.append(Field(number: number, wire: wire, data: Data(d[i..<(i + 4)])))
                i += 4
            default:
                return out
            }
        }
        return out
    }

    private static func message(_ d: Data, path: [Int]) -> Data? {
        var current = d
        for number in path {
            guard let next = fields(current).first(where: { $0.number == number && $0.wire == 2 }) else { return nil }
            current = next.data
        }
        return current
    }
}

struct Pannini {
    static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    struct CatmullRom { float2 w0; float2 w12; float2 w3; float2 o12; };

    float2 panniniSource(float2 q, float2 center, float fsrc, float fout, float d, float rotated) {
        float2 p = (q - center) / fout;
        if (rotated > 0.5) p = p.yx;
        float k = p.x * p.x / ((d + 1.0) * (d + 1.0));
        float dscr = k * k * d * d - (k + 1.0) * (k * d * d - 1.0);
        float clon = (-k * d + sqrt(max(dscr, 0.0))) / (k + 1.0);
        float s = (d + 1.0) / (d + clon);
        float lon = atan2(p.x, s * clon);
        float lat = atan(p.y / s);
        float2 r = float2(tan(lon), tan(lat) / cos(lon));
        if (rotated > 0.5) r = r.yx;
        return center + r * fsrc - 0.5;
    }

    CatmullRom catmullRom(float2 f) {
        CatmullRom c;
        c.w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        c.w3 = f * f * (-0.5 + 0.5 * f);
        c.w12 = w1 + w2;
        c.o12 = w2 / c.w12;
        return c;
    }

    [[stitchable]] float2 panniniTap(float2 center, float fsrc, float fout, float d, float rotated, float2 tap, coreimage::destination dest) {
        float2 t = panniniSource(dest.coord(), center, fsrc, fout, d, rotated);
        float2 base = floor(t);
        CatmullRom c = catmullRom(t - base);
        return base + 0.5 + select(select(float2(2.0), c.o12, tap < 1.5), float2(-1.0), tap < 0.5);
    }

    [[stitchable]] float4 panniniMix(coreimage::sample_t top, coreimage::sample_t left, coreimage::sample_t mid, coreimage::sample_t right, coreimage::sample_t bottom, float2 center, float fsrc, float fout, float d, float rotated, coreimage::destination dest) {
        float2 t = panniniSource(dest.coord(), center, fsrc, fout, d, rotated);
        CatmullRom c = catmullRom(t - floor(t));
        float a = c.w12.x * c.w0.y, b = c.w0.x * c.w12.y, m = c.w12.x * c.w12.y, e = c.w3.x * c.w12.y, g = c.w12.x * c.w3.y;
        return (top * a + left * b + mid * m + right * e + bottom * g) / (a + b + m + e + g);
    }
    """

    let tap: CIWarpKernel
    let mix: CIColorKernel
    let d: Double
    let focalMM: Double
    var rotated = false

    init(strength: Double, focalMM: Double) throws {
        let kernels = try CIKernel.kernels(withMetalString: Pannini.source)
        guard let tap = kernels.first(where: { $0.name == "panniniTap" }) as? CIWarpKernel,
              let mix = kernels.first(where: { $0.name == "panniniMix" }) as? CIColorKernel else {
            throw ToolError.usage("Core Image warp kernels unavailable; got \(kernels.map(\.name))")
        }
        self.tap = tap
        self.mix = mix
        d = strength
        self.focalMM = focalMM
    }

    func apply(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let (fsrc, fout) = focals(for: extent)
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let source = image.clampedToExtent()
        let common: [Any] = [CIVector(cgPoint: center), Float(fsrc), Float(fout), Float(d), Float(rotated ? 1 : 0)]
        let taps = [(1, 0), (0, 1), (1, 1), (2, 1), (1, 2)].compactMap { x, y in
            tap.apply(extent: extent, roiCallback: { _, rect in sourceRect(rect, center: center, fsrc: fsrc, fout: fout) },
                      image: source, arguments: common + [CIVector(x: CGFloat(x), y: CGFloat(y))])
        }
        guard taps.count == 5, let mixed = mix.apply(extent: extent, arguments: taps + common) else { return image }
        return mixed.cropped(to: extent)
    }

    func scale(at point: CGPoint, in extent: CGRect) -> Double {
        let (fsrc, fout) = focals(for: extent)
        let lon = atan(Double(rotated ? point.y - extent.midY : point.x - extent.midX) / fsrc)
        return fout / fsrc * (d + 1) * cos(lon) / (d + cos(lon))
    }

    private func focals(for extent: CGRect) -> (Double, Double) {
        let w = Double(extent.width), h = Double(extent.height)
        let fsrc = focalMM * (w * w + h * h).squareRoot() / 43.27
        let half = (rotated ? h : w) / 2
        let lonMax = atan(half / fsrc)
        return (fsrc, half * (d + cos(lonMax)) / ((d + 1) * sin(lonMax)))
    }

    private func map(_ point: CGPoint, center: CGPoint, fsrc: Double, fout: Double) -> CGPoint {
        var u = Double(point.x - center.x) / fout
        var v = Double(point.y - center.y) / fout
        if rotated { swap(&u, &v) }
        let k = u * u / ((d + 1) * (d + 1))
        let dscr = k * k * d * d - (k + 1) * (k * d * d - 1)
        let clon = (-k * d + max(dscr, 0).squareRoot()) / (k + 1)
        let s = (d + 1) / (d + clon)
        let lon = atan2(u, s * clon)
        let lat = atan(v / s)
        var x = tan(lon), y = tan(lat) / cos(lon)
        if rotated { swap(&x, &y) }
        return CGPoint(x: Double(center.x) + x * fsrc, y: Double(center.y) + y * fsrc)
    }

    private func sourceRect(_ rect: CGRect, center: CGPoint, fsrc: Double, fout: Double) -> CGRect {
        let xs = [rect.minX, rect.maxX] + (rect.minX < center.x && center.x < rect.maxX ? [center.x] : [])
        let ys = [rect.minY, rect.maxY] + (rect.minY < center.y && center.y < rect.maxY ? [center.y] : [])
        let points = xs.flatMap { x in ys.map { y in map(CGPoint(x: x, y: y), center: center, fsrc: fsrc, fout: fout) } }
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -3, dy: -3)
    }
}
