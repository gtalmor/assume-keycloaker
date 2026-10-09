import AppKit
import CloakerCore
import ScreenCaptureKit
import Vision

/// Finds QR codes (e.g. an authenticator's otpauth:// QR) in images, the clipboard or the screen.
enum QRReader {
    static func payloads(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    static func payloads(in image: NSImage) -> [String] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return payloads(in: cg)
    }

    /// Text or an image on the clipboard (⌃⇧⌘4 puts a screenshot there).
    static func clipboard() -> (text: String?, qr: [String]) {
        let pb = NSPasteboard.general
        let text = pb.string(forType: .string)
        let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []
        return (text, images.flatMap(payloads(in:)))
    }

    static var canCaptureScreen: Bool { CGPreflightScreenCaptureAccess() }

    /// Every display, without Assume Cloaker's own windows. Asks for Screen Recording access the first
    /// time (macOS then wants the app reopened).
    static func screens() async throws -> [CGImage] {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ToolError("Allow Assume Cloaker under System Settings → Privacy & Security → Screen Recording, reopen it, and try again. Or paste a screenshot of the QR instead (⌃⇧⌘4).")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        var images: [CGImage] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width * 2
            config.height = display.height * 2
            config.showsCursor = false
            images.append(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config))
        }
        return images
    }
}
