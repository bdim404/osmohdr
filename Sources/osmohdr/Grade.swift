import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

struct CubeLUT {
    let size: Int
    let data: Data

    init(url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var values: [Float] = []
        values.reserveCapacity(65 * 65 * 65 * 4)
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = fields.first, !head.hasPrefix("#") else { continue }
            if head == "LUT_3D_SIZE", fields.count > 1, let n = Int(fields[1]) {
                size = n
                continue
            }
            if head == "LUT_1D_SIZE" { throw ToolError.badLUT(url.path) }
            guard fields.count == 3, let r = Float(fields[0]), let g = Float(fields[1]), let b = Float(fields[2]) else { continue }
            values.append(contentsOf: [r, g, b, 1])
        }
        guard size > 1, values.count == size * size * size * 4 else { throw ToolError.badLUT(url.path) }
        self.size = size
        self.data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func apply(_ image: CIImage) -> CIImage {
        let filter = CIFilter.colorCube()
        filter.inputImage = image
        filter.cubeDimension = Float(size)
        filter.cubeData = data
        return filter.outputImage ?? image
    }
}
