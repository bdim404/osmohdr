import AVFoundation
import CoreImage
import VideoToolbox

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class FrameQueue<T>: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [T] = []
    private var finished = false
    private var cancelled = false
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    func push(_ item: T) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while items.count >= capacity && !cancelled { condition.wait() }
        guard !cancelled else { return false }
        items.append(item)
        condition.broadcast()
        return true
    }

    func pop() -> T? {
        condition.lock()
        defer { condition.unlock() }
        while items.isEmpty && !finished && !cancelled { condition.wait() }
        guard !cancelled, !items.isEmpty else { return nil }
        let item = items.removeFirst()
        condition.broadcast()
        return item
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        items.removeAll()
        condition.broadcast()
        condition.unlock()
    }
}

struct Frame {
    let sample: CMSampleBuffer
    let image: CIImage
    let extent: CGRect
    let analysis: Beauty.Analysis?
}

final class Renderer {
    let context: CIContext
    let lut: CubeLUT
    var lens: Pannini?
    let beauty: Beauty?
    let showMask: Bool

    init(context: CIContext, lut: CubeLUT, lens: Pannini?, beauty: Beauty?, showMask: Bool) {
        self.context = context
        self.lut = lut
        self.lens = lens
        self.beauty = beauty
        self.showMask = showMask
    }

    func prepare(_ sample: CMSampleBuffer) -> Frame? {
        guard let src = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let input = CIImage(cvPixelBuffer: src, options: [.colorSpace: NSNull()])
        let graded = lut.apply(input)
        let analysis = beauty?.prepare(graded, lens: lens)
        let image = lens.map { lut.apply($0.apply(input)) } ?? graded
        return Frame(sample: sample, image: image, extent: input.extent, analysis: analysis)
    }

    func start(_ frame: Frame, into dst: CVPixelBuffer) throws -> CIRenderTask {
        CVBufferSetAttachment(dst, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(dst, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(dst, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        var image = frame.image
        if let beauty, let analysis = frame.analysis { image = beauty.render(image, analysis, lens: lens, showMask: showMask) }
        let destination = CIRenderDestination(pixelBuffer: dst)
        destination.colorSpace = nil
        return try context.startTask(toRender: image.cropped(to: frame.extent), from: frame.extent, to: destination, at: .zero)
    }
}

func convertVideo(input: URL, output: URL, options: Options, renderer: Renderer, progress: Bool) async throws {
    let asset = AVURLAsset(url: input)
    guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else { throw ToolError.noVideo(input.path) }
    let (size, transform, fps, timeScale) = try await vtrack.load(.naturalSize, .preferredTransform, .nominalFrameRate, .naturalTimeScale)
    let duration = try await asset.load(.duration)
    let atrack = try await asset.loadTracks(withMediaType: .audio).first
    let audioFormat = try await atrack?.load(.formatDescriptions).first

    let reader = try AVAssetReader(asset: asset)
    let pixelAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
    ]
    let vout = AVAssetReaderTrackOutput(track: vtrack, outputSettings: pixelAttributes)
    vout.alwaysCopiesSampleData = false
    reader.add(vout)
    let aout = atrack.map { AVAssetReaderTrackOutput(track: $0, outputSettings: nil) }
    if let aout { reader.add(aout) }

    try? FileManager.default.removeItem(at: output)
    let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
    writer.movieTimeScale = timeScale
    let width = Int(size.width), height = Int(size.height)
    let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
        ],
        AVVideoCompressionPropertiesKey: [
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            AVVideoAverageBitRateKey: options.bitrate * 1_000_000,
            AVVideoExpectedSourceFrameRateKey: Int(fps.rounded())
        ]
    ])
    vin.expectsMediaDataInRealTime = false
    vin.transform = transform
    vin.mediaTimeScale = timeScale
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: vin,
        sourcePixelBufferAttributes: pixelAttributes.merging([kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height]) { $1 }
    )
    writer.add(vin)
    var ain: AVAssetWriterInput?
    if aout != nil {
        let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
        i.expectsMediaDataInRealTime = false
        writer.add(i)
        ain = i
    }
    if let created = try? await asset.load(.creationDate), let date = try? await created.load(.dateValue) {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataCreationDate
        item.value = ISO8601DateFormatter().string(from: date) as NSString
        writer.metadata = [item]
    }

    guard reader.startReading() else { throw ToolError.reader(reader.error?.localizedDescription ?? "unknown") }
    guard writer.startWriting() else { throw ToolError.writer(writer.error?.localizedDescription ?? "unknown") }
    writer.startSession(atSourceTime: .zero)

    renderer.beauty?.analysisInterval = fps > 40 ? 2 : 1
    renderer.lens?.rotated = abs(transform.b) > 0.5
    let total = options.limit ?? max(1, Int((duration.seconds * Double(fps)).rounded()))
    let endTime = options.limit.map { CMTime(seconds: Double($0) / Double(fps), preferredTimescale: 600_000) } ?? .positiveInfinity
    let group = DispatchGroup()
    let failure = Box<Error?>(nil)
    let started = Date()

    let queue = FrameQueue<Frame>(capacity: 8)
    DispatchQueue(label: "osmohdr.prepare", qos: .userInitiated).async {
        var read = 0
        while options.limit == nil || read < total {
            guard let sample = vout.copyNextSampleBuffer() else { break }
            guard let frame = autoreleasepool(invoking: { renderer.prepare(sample) }) else { continue }
            read += 1
            guard queue.push(frame) else { break }
        }
        queue.finish()
    }

    group.enter()
    let videoDone = Box(false)
    var frames = 0
    var drained = false
    var inFlight: [(frame: Frame, buffer: CVPixelBuffer, task: CIRenderTask)] = []
    let depth = 3
    vin.requestMediaDataWhenReady(on: DispatchQueue(label: "osmohdr.video", qos: .userInitiated)) {
        func finish() {
            guard !videoDone.value else { return }
            videoDone.value = true
            inFlight.removeAll()
            queue.cancel()
            vin.markAsFinished()
            group.leave()
        }
        func fail(_ error: Error) {
            failure.value = error
            finish()
        }
        while !videoDone.value && vin.isReadyForMoreMediaData {
            if !drained && inFlight.count < depth {
                guard let frame = queue.pop() else {
                    drained = true
                    continue
                }
                var dst: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess, let dst else {
                    return fail(ToolError.writer("pixel buffer pool unavailable"))
                }
                do {
                    let task = try autoreleasepool { try renderer.start(frame, into: dst) }
                    inFlight.append((frame, dst, task))
                } catch {
                    return fail(error)
                }
                if inFlight.count < depth { continue }
            }
            guard !inFlight.isEmpty else { return finish() }
            let oldest = inFlight.removeFirst()
            do {
                _ = try oldest.task.waitUntilCompleted()
            } catch {
                return fail(error)
            }
            guard adaptor.append(oldest.buffer, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(oldest.frame.sample)) else {
                return fail(ToolError.writer(writer.error?.localizedDescription ?? "append failed"))
            }
            frames += 1
            if progress && (frames % 15 == 0 || frames == total) {
                let elapsed = Date().timeIntervalSince(started)
                let rate = Double(frames) / max(elapsed, 0.001)
                let eta = Double(max(total - frames, 0)) / max(rate, 0.001)
                FileHandle.standardError.write(String(format: "\r  %d/%d frames  %.1f fps  eta %.0fs   ", frames, total, rate, eta).data(using: .utf8)!)
            }
        }
    }

    if let ain, let aout {
        group.enter()
        let audioDone = Box(false)
        ain.requestMediaDataWhenReady(on: DispatchQueue(label: "osmohdr.audio")) {
            while !audioDone.value && ain.isReadyForMoreMediaData {
                guard let sample = aout.copyNextSampleBuffer(), CMSampleBufferGetPresentationTimeStamp(sample) < endTime else {
                    audioDone.value = true
                    ain.markAsFinished()
                    group.leave()
                    return
                }
                ain.append(sample)
            }
        }
    }

    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        group.notify(queue: .global()) { c.resume() }
    }
    if progress { FileHandle.standardError.write("\n".data(using: .utf8)!) }
    if let error = failure.value {
        writer.cancelWriting()
        reader.cancelReading()
        throw error
    }
    if reader.status == .failed {
        writer.cancelWriting()
        throw ToolError.reader(reader.error?.localizedDescription ?? "unknown")
    }
    if reader.status == .reading { reader.cancelReading() }
    await writer.finishWriting()
    guard writer.status == .completed else { throw ToolError.writer(writer.error?.localizedDescription ?? "unknown") }
    let elapsed = Date().timeIntervalSince(started)
    print(String(format: "  done: %@  %d frames in %.1fs (%.1f fps)", input.lastPathComponent, frames, elapsed, Double(frames) / max(elapsed, 0.001)))
}
