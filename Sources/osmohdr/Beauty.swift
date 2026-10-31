import CoreImage
import CoreGraphics
import Vision
import simd

final class Beauty {
    struct Analysis {
        let person: [Float]
        let personWidth: Int
        let personHeight: Int
        let feature: [Float]
        let faceRegion: [Float]
        let width: Int
        let height: Int
        let skinMean: SIMD2<Float>
        let skinCov: simd_float2x2
        let faceSigma: Double
    }

    static let defaultMean = SIMD2<Float>(-0.051, 0.0715)
    static let defaultCov = simd_float2x2(SIMD2<Float>(0.000518, -0.000566), SIMD2<Float>(-0.000566, 0.001008))

    static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    constant float3 kLuma = float3(0.2627, 0.6780, 0.0593);

    [[stitchable]] float4 gfPack(coreimage::sample_t s) {
        return float4(s.rgb * dot(s.rgb, kLuma), 1.0);
    }

    [[stitchable]] float4 gfCoefA(coreimage::sample_t m1, coreimage::sample_t m2, float eps) {
        float my = dot(m1.rgb, kLuma);
        float v = max(dot(m2.rgb, kLuma) - my * my, 0.0);
        return float4((m2.rgb - m1.rgb * my) / (v + eps), 1.0);
    }

    [[stitchable]] float4 skinMask(coreimage::sample_t m1, coreimage::sample_t person, coreimage::sample_t feature, coreimage::sample_t face, float2 mean, float3 icov) {
        float y = dot(m1.rgb, kLuma);
        float2 c = float2((m1.b - y) / 1.8814, (m1.r - y) / 1.4746);
        float2 d = c - mean;
        float md = d.x * d.x * icov.x + 2.0 * d.x * d.y * icov.y + d.y * d.y * icov.z;
        float lum = smoothstep(0.04, 0.12, y) * (1.0 - smoothstep(0.85, 0.97, y));
        float warm = smoothstep(0.012, 0.04, c.y) * (1.0 - smoothstep(-0.01, 0.01, c.x));
        float p = exp(-0.5 * md) * warm * lum * person.r;
        float loose = exp(-0.125 * md) * smoothstep(0.0, 0.015, c.y) * lum;
        float m = clamp(max(p, face.r * loose) * (1.0 - feature.r), 0.0, 1.0);
        return float4(m, m, m, 1.0);
    }

    [[stitchable]] float4 beautyMix(coreimage::sample_t s, coreimage::sample_t a, coreimage::sample_t mm, coreimage::sample_t mask, float smooth, float whiten) {
        float y = dot(s.rgb, kLuma);
        float3 q = a.rgb * (y - dot(mm.rgb, kLuma)) + mm.rgb;
        float m = smoothstep(0.05, 0.6, mask.r);
        float3 o = mix(s.rgb, q, clamp(smooth * m, 0.0, 1.0));
        float w = whiten * m;
        float yo = dot(o, kLuma);
        o += w * 0.0245 * smoothstep(0.03, 0.12, yo) * (1.0 - smoothstep(0.58, 0.8, yo));
        float yw = dot(o, kLuma);
        o = mix(float3(yw), o, 1.0 - w * 0.3 * (yw - 0.4) * (1.0 - smoothstep(0.7, 0.85, yw)));
        return float4(o, 1.0);
    }

    [[stitchable]] float4 maskView(coreimage::sample_t mask) {
        return float4(mask.rrr, 1.0);
    }
    """

    private let context: CIContext
    private let smooth: Float
    private let whiten: Float
    private let pack: CIColorKernel
    private let coefA: CIColorKernel
    private let skin: CIColorKernel
    private let blend: CIColorKernel
    private let view: CIColorKernel
    private let sequence = VNSequenceRequestHandler()
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private let landmarks = VNDetectFaceLandmarksRequest()
    private var pool: CVPixelBufferPool?
    private var frameCount = 0
    var analysisInterval = 1
    private var analysisWidth = 0
    private var analysisHeight = 0
    private var person: [Float] = []
    private var personWidth = 0
    private var personHeight = 0
    private var feature: [Float] = []
    private var faceRegion: [Float] = []
    private var skinMean = Beauty.defaultMean
    private var skinCov = Beauty.defaultCov
    private var faceSigma: Double = 0

    init(context: CIContext, smooth: Float, whiten: Float) throws {
        self.context = context
        self.smooth = smooth
        self.whiten = whiten
        let kernels = try CIKernel.kernels(withMetalString: Beauty.source)
        func kernel(_ name: String) throws -> CIColorKernel {
            guard let k = kernels.first(where: { $0.name == name }) as? CIColorKernel else {
                throw ToolError.usage("Core Image kernel \(name) unavailable; got \(kernels.map(\.name))")
            }
            return k
        }
        pack = try kernel("gfPack")
        coefA = try kernel("gfCoefA")
        skin = try kernel("skinMask")
        blend = try kernel("beautyMix")
        view = try kernel("maskView")
        segmentation.qualityLevel = .fast
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func prepare(_ image: CIImage, lens: Pannini?) -> Analysis {
        if frameCount % analysisInterval == 0 || person.isEmpty { analyze(image, lens: lens) }
        frameCount += 1
        return Analysis(person: person, personWidth: personWidth, personHeight: personHeight, feature: feature, faceRegion: faceRegion,
                        width: analysisWidth, height: analysisHeight, skinMean: skinMean, skinCov: skinCov, faceSigma: faceSigma)
    }

    func render(_ image: CIImage, _ analysis: Analysis, lens: Pannini?, showMask: Bool) -> CIImage {
        let extent = image.extent
        let k = min(0.5, max(0.25, 960 / extent.width))
        let half = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let halfExtent = half.extent.integral
        let sigma = 6.0 * Double(k) * Double(extent.width / 3840)
        let smoothSigma = analysis.faceSigma > 0 ? analysis.faceSigma * Double(k) : sigma
        func blur(_ i: CIImage, _ s: Double? = nil) -> CIImage {
            i.clampedToExtent().applyingGaussianBlur(sigma: s ?? sigma).cropped(to: halfExtent)
        }
        func upscale(_ i: CIImage) -> CIImage {
            i.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: extent.width / halfExtent.width, y: extent.height / halfExtent.height))
                .cropped(to: extent)
        }
        let eps: Float = 0.0008
        let m1 = blur(half.cropped(to: halfExtent), smoothSigma)
        let m2 = blur(pack.apply(extent: halfExtent, arguments: [half])!, smoothSigma)
        let a = blur(coefA.apply(extent: halfExtent, arguments: [m1, m2, eps])!, smoothSigma)
        func warped(_ i: CIImage) -> CIImage { lens?.apply(i) ?? i }
        let personImage = warped(maskImage(analysis.person, width: analysis.personWidth, height: analysis.personHeight, extent: halfExtent))
        let featureImage = warped(maskImage(analysis.feature, width: analysis.width, height: analysis.height, extent: halfExtent))
        let faceImage = warped(maskImage(analysis.faceRegion, width: analysis.width, height: analysis.height, extent: halfExtent))
        let inv = (analysis.skinCov * 2).inverse
        let mask = skin.apply(extent: halfExtent, arguments: [
            m1, personImage, featureImage, faceImage,
            CIVector(x: CGFloat(analysis.skinMean.x), y: CGFloat(analysis.skinMean.y)),
            CIVector(x: CGFloat(inv[0][0]), y: CGFloat(inv[0][1]), z: CGFloat(inv[1][1]))
        ])!
        let fullMask = upscale(blur(mask))
        if showMask { return view.apply(extent: extent, arguments: [fullMask])! }
        return blend.apply(extent: extent, arguments: [image, upscale(a), upscale(blur(m1, smoothSigma)), fullMask, smooth * 0.46, whiten])!
    }

    private func maskImage(_ values: [Float], width: Int, height: Int, extent: CGRect) -> CIImage {
        guard width > 0, height > 0, values.count == width * height else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: width * 4, size: CGSize(width: width, height: height), format: .Lf, colorSpace: nil)
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
            .cropped(to: extent)
    }

    private func analyze(_ image: CIImage, lens: Pannini?) {
        let extent = image.extent
        let w = 768
        let h = Int((CGFloat(w) * extent.height / extent.width).rounded())
        if pool == nil || w != analysisWidth || h != analysisHeight {
            analysisWidth = w
            analysisHeight = h
            feature = []
            faceRegion = []
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        let small = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / extent.width, y: CGFloat(h) / extent.height))
        context.render(small, to: buffer, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: nil)
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            if i == 0 {
                try? sequence.perform([segmentation], on: buffer)
            } else {
                try? VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([landmarks])
            }
        }
        updatePerson()
        let faces = landmarks.results ?? []
        updateFeatures(faces)
        updateSkinModel(buffer, faces)
        let scale = Double(extent.width / 3840)
        let largest = faces.map { face -> Double in
            let box = face.boundingBox
            let center = CGPoint(x: extent.minX + box.midX * extent.width, y: extent.minY + box.midY * extent.height)
            return Double(box.height) * (lens?.scale(at: center, in: extent) ?? 1)
        }.max()
        let target = largest.map { min(max(0.0146 * $0 * Double(extent.height), 3 * scale), 14 * scale) } ?? 6 * scale
        faceSigma = faceSigma > 0 ? 0.85 * faceSigma + 0.15 * target : target
    }

    private func updatePerson() {
        guard let pb = segmentation.results?.first?.pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let mw = CVPixelBufferGetWidth(pb), mh = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return }
        var current = [Float](repeating: 0, count: mw * mh)
        for y in 0..<mh {
            for x in 0..<mw { current[y * mw + x] = Float(base[y * stride + x]) / 255 }
        }
        if mw == personWidth && mh == personHeight && person.count == current.count {
            for i in 0..<current.count { person[i] = 0.6 * current[i] + 0.4 * person[i] }
        } else {
            person = current
            personWidth = mw
            personHeight = mh
        }
    }

    private func updateFeatures(_ faces: [VNFaceObservation]) {
        let w = analysisWidth, h = analysisHeight
        func canvas() -> CGContext? {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.setFillColor(gray: 0, alpha: 1)
            ctx?.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx?.setFillColor(gray: 1, alpha: 1)
            return ctx
        }
        guard let ctx = canvas(), let faceCtx = canvas() else { return }
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        for face in faces {
            guard let lm = face.landmarks else { continue }
            let box = face.boundingBox
            let faceWidth = box.width * CGFloat(w)
            func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                guard let region else { return [] }
                return region.normalizedPoints.map {
                    CGPoint(x: (box.minX + $0.x * box.width) * CGFloat(w), y: (box.minY + $0.y * box.height) * CGFloat(h))
                }
            }
            let contour = points(lm.faceContour)
            if contour.count >= 5 {
                let first = contour[0], last = contour[contour.count - 1], chin = contour[contour.count / 2]
                let mid = CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
                let upLength = max(hypot(mid.x - chin.x, mid.y - chin.y), 1)
                let up = CGVector(dx: (mid.x - chin.x) / upLength, dy: (mid.y - chin.y) / upLength)
                let rx = max(hypot(last.x - first.x, last.y - first.y) / 2, 1)
                let right = CGVector(dx: (last.x - first.x) / (2 * rx), dy: (last.y - first.y) / (2 * rx))
                let ry = upLength * 0.7
                var outline = contour
                for i in 0...16 {
                    let t = CGFloat(i) / 16 * .pi
                    outline.append(CGPoint(x: mid.x + right.dx * rx * cos(t) + up.dx * ry * sin(t), y: mid.y + right.dy * rx * cos(t) + up.dy * ry * sin(t)))
                }
                faceCtx.beginPath()
                faceCtx.addLines(between: outline)
                faceCtx.closePath()
                faceCtx.fillPath()
            }
            for (region, width, closed) in [
                (lm.leftEye, 0.07, true), (lm.rightEye, 0.07, true),
                (lm.leftEyebrow, 0.06, false), (lm.rightEyebrow, 0.06, false),
                (lm.outerLips, 0.04, true), (lm.nose, 0.015, false)
            ] {
                let p = points(region)
                guard p.count > 1 else { continue }
                ctx.setLineWidth(faceWidth * CGFloat(width))
                ctx.beginPath()
                ctx.addLines(between: p)
                if closed {
                    ctx.closePath()
                    ctx.drawPath(using: .fillStroke)
                } else {
                    ctx.strokePath()
                }
            }
        }
        func merge(_ source: CGContext, into values: inout [Float]) {
            guard let data = source.data?.assumingMemoryBound(to: UInt8.self) else { return }
            var current = [Float](repeating: 0, count: w * h)
            for i in 0..<current.count { current[i] = Float(data[i]) / 255 }
            if values.count == current.count {
                for i in 0..<current.count { values[i] = max(current[i], 0.5 * values[i]) }
            } else {
                values = current
            }
        }
        merge(ctx, into: &feature)
        merge(faceCtx, into: &faceRegion)
    }

    private func updateSkinModel(_ buffer: CVPixelBuffer, _ faces: [VNFaceObservation]) {
        guard !faces.isEmpty else {
            skinMean = 0.97 * skinMean + 0.03 * Beauty.defaultMean
            skinCov = 0.97 * skinCov + 0.03 * Beauty.defaultCov
            return
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let w = analysisWidth, h = analysisHeight
        var n: Float = 0
        var sum = SIMD2<Float>(0, 0)
        var sq = SIMD3<Float>(0, 0, 0)
        for face in faces {
            let box = face.boundingBox
            let x0 = max(0, Int((box.minX + 0.2 * box.width) * CGFloat(w)))
            let x1 = min(w, Int((box.minX + 0.8 * box.width) * CGFloat(w)))
            let y0 = max(0, Int((box.minY + 0.15 * box.height) * CGFloat(h)))
            let y1 = min(h, Int((box.minY + 0.75 * box.height) * CGFloat(h)))
            guard x1 > x0, y1 > y0 else { continue }
            for yb in y0..<y1 {
                let row = h - 1 - yb
                for x in x0..<x1 {
                    if !feature.isEmpty && feature[row * w + x] > 0.2 { continue }
                    if personWidth > 0 {
                        let px = min(personWidth - 1, x * personWidth / w), py = min(personHeight - 1, row * personHeight / h)
                        if person[py * personWidth + px] < 0.5 { continue }
                    }
                    let p = base + row * stride + x * 4
                    let b = Float(p[0]) / 255, g = Float(p[1]) / 255, r = Float(p[2]) / 255
                    let y = 0.2627 * r + 0.6780 * g + 0.0593 * b
                    if y < 0.08 || y > 0.9 { continue }
                    let c = SIMD2<Float>((b - y) / 1.8814, (r - y) / 1.4746)
                    n += 1
                    sum += c
                    sq += SIMD3<Float>(c.x * c.x, c.x * c.y, c.y * c.y)
                }
            }
        }
        guard n > 150 else { return }
        let mean = sum / n
        var cov = simd_float2x2(
            SIMD2<Float>(sq.x / n - mean.x * mean.x, sq.y / n - mean.x * mean.y),
            SIMD2<Float>(sq.y / n - mean.x * mean.y, sq.z / n - mean.y * mean.y)
        )
        cov = 0.75 * cov + 0.25 * Beauty.defaultCov
        cov[0][0] = max(cov[0][0], 0.0002)
        cov[1][1] = max(cov[1][1], 0.0002)
        let target = 0.75 * mean + 0.25 * Beauty.defaultMean
        skinMean = 0.8 * skinMean + 0.2 * target
        skinCov = 0.8 * skinCov + 0.2 * cov
    }
}
