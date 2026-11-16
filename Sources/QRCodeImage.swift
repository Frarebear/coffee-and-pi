import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum QRCodeImage {
    static func cgImage(from string: String, dimension: CGFloat = 220) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = dimension / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        return context.createCGImage(scaled, from: scaled.extent)
    }

    static func nsImage(from string: String, dimension: CGFloat = 220) -> NSImage? {
        guard let cg = cgImage(from: string, dimension: dimension) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: dimension, height: dimension))
    }
}

struct QRCodeView: View {
    let string: String
    var size: CGFloat = 200

    var body: some View {
        Group {
            if let image = QRCodeImage.nsImage(from: string, dimension: size) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
                    .accessibilityLabel("Pairing QR code")
            } else {
                Text("QR unavailable")
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
    }
}
