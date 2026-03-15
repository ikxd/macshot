import Cocoa
import ScreenCaptureKit
import Accelerate

// MARK: - ScrollCaptureController

/// Manages a scroll-capture session: listens for scroll events, captures strips of
/// the selected region after scrolling settles, and stitches them together using
/// SAD (sum of absolute differences) template matching to find the exact overlap.
@MainActor
final class ScrollCaptureController {

    // MARK: - Public state

    private(set) var stripCount: Int = 0

    /// Live stitched result in Retina pixels (grows as strips are added).
    private(set) var stitchedImage: CGImage?
    private(set) var stitchedPixelSize: CGSize = .zero

    private(set) var isActive: Bool = false

    // MARK: - Callbacks

    var onStripAdded:  ((Int) -> Void)?  // stripCount
    var onSessionDone: ((NSImage?) -> Void)?

    // MARK: - Private

    /// The region to capture in AppKit screen coordinates (bottom-left origin, points).
    private let captureRect: NSRect
    private let screen: NSScreen

    private var scDisplay: SCDisplay?

    /// Scroll event monitor (global, passive — no Accessibility permission needed).
    private var scrollMonitor: Any?

    /// Debounce timer: fires after scroll velocity has settled.
    private var debounceTimer: Timer?
    private let debounceInterval: TimeInterval = 0.40

    /// Minimum pixel movement to bother appending a new strip (avoids jitter duplicates).
    private let minNewContentPx = 4

    /// Canvas is grown downward (vertical scroll). Support horizontal is future work.
    private var canvasWidthPx:  Int = 0
    private var canvasHeightPx: Int = 0

    // MARK: - Init

    init(captureRect: NSRect, screen: NSScreen) {
        self.captureRect = captureRect
        self.screen      = screen
    }

    // MARK: - Session

    func startSession() async {
        guard !isActive else { return }

        // Resolve the SCDisplay for this screen
        if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
            scDisplay = content.displays.first(where: { d in
                abs(d.frame.origin.x - screen.frame.origin.x) < 2 &&
                abs(d.frame.origin.y - (NSScreen.screens.map(\.frame.maxY).max() ?? 0) - screen.frame.origin.y) < 50
            }) ?? content.displays.first
        }
        guard scDisplay != nil else {
            onSessionDone?(nil)
            return
        }

        // Capture the first strip immediately
        guard let first = await captureStrip() else {
            onSessionDone?(nil)
            return
        }

        isActive = true
        appendFirstStrip(first)
        onStripAdded?(stripCount)

        // Install global scroll monitor
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.scheduleDebounce()
        }
    }

    func stopSession() {
        isActive = false
        debounceTimer?.invalidate()
        debounceTimer = nil
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        deliverResult()
    }

    // MARK: - Scroll debounce

    private func scheduleDebounce() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in await self.onScrollSettled() }
        }
    }

    private func onScrollSettled() async {
        guard isActive else { return }
        guard let newStrip = await captureStrip() else { return }
        guard let lastStrip = lastCapturedStrip else { return }

        let overlap = findOverlap(previous: lastStrip, next: newStrip)
        let newContentPx = newStrip.height - overlap.overlapPx

        // Discard if no new content (identical frame or tiny jitter)
        guard newContentPx >= minNewContentPx else { return }

        appendStrip(newStrip, overlapPx: overlap.overlapPx)
        onStripAdded?(stripCount)
    }

    // MARK: - Strip capture

    /// The most recently captured raw strip (used as template for overlap detection).
    private var lastCapturedStrip: CGImage?

    private func captureStrip() async -> CGImage? {
        guard let display = scDisplay else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = captureRect
        config.width  = Int(captureRect.width  * screen.backingScaleFactor)
        config.height = Int(captureRect.height * screen.backingScaleFactor)
        config.showsCursor = false
        config.captureResolution = .best
        guard let raw = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        let cpu = copyToCPUBacked(raw) ?? raw
        lastCapturedStrip = cpu
        return cpu
    }

    // MARK: - Stitching

    private func appendFirstStrip(_ strip: CGImage) {
        canvasWidthPx  = strip.width
        canvasHeightPx = strip.height
        stitchedImage  = strip
        stitchedPixelSize = CGSize(width: canvasWidthPx, height: canvasHeightPx)
        stripCount = 1
    }

    private func appendStrip(_ strip: CGImage, overlapPx: Int) {
        let newContentH = max(0, strip.height - overlapPx)
        guard newContentH > 0 else { return }

        let newTotalH = canvasHeightPx + newContentH
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: canvasWidthPx, height: newTotalH,
            bitsPerComponent: 8,
            bytesPerRow: canvasWidthPx * 4,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else { return }

        // CGContext uses bottom-left origin.
        // Existing stitched content goes at the top (y = newContentH).
        if let existing = stitchedImage {
            ctx.draw(existing, in: CGRect(x: 0, y: newContentH,
                                          width: canvasWidthPx, height: canvasHeightPx))
        }

        // New content is the non-overlapping bottom portion of the incoming strip.
        // In CG top-left bitmap coords, the non-overlapping part starts at y = overlapPx.
        if let newContent = strip.cropping(to: CGRect(
            x: 0, y: overlapPx, width: strip.width, height: newContentH
        )) {
            ctx.draw(newContent, in: CGRect(x: 0, y: 0, width: canvasWidthPx, height: newContentH))
        }

        canvasHeightPx = newTotalH
        stitchedImage  = ctx.makeImage()
        stitchedPixelSize = CGSize(width: canvasWidthPx, height: canvasHeightPx)
        stripCount += 1
    }

    // MARK: - Overlap detection (SAD template matching)

    private struct OverlapResult {
        let overlapPx:  Int    // how many rows at the top of `next` overlap with `previous`
        let confidence: Float  // 0–1; 1 = perfect match
    }

    /// Finds the exact pixel overlap between two consecutive strips.
    ///
    /// Algorithm:
    ///   - Take a horizontal band from the **bottom** of `previous` as the search template.
    ///   - Scan it downward through the **top portion** of `next` using sum of absolute
    ///     differences (SAD), computed via vDSP for speed.
    ///   - The row offset of the minimum SAD gives the overlap.
    ///
    /// This handles all scroll speeds correctly, including slow micro-scrolls and
    /// fast page-jumps up to half the strip height.
    private func findOverlap(previous: CGImage, next: CGImage) -> OverlapResult {
        let scale        = Int(screen.backingScaleFactor)
        let templateH    = max(32, 32 * scale)   // ~32 pt in Retina pixels
        let stripW       = previous.width

        guard previous.height > templateH * 2,
              next.height >= templateH,
              next.width == stripW else {
            return OverlapResult(overlapPx: 0, confidence: 0)
        }

        // Template = bottom `templateH` rows of `previous`
        let templateY = previous.height - templateH
        guard let templateCG = previous.cropping(to: CGRect(
            x: 0, y: templateY, width: stripW, height: templateH
        )) else { return OverlapResult(overlapPx: 0, confidence: 0) }

        // Search region = top (searchH + templateH) rows of `next`.
        // We scan up to half the strip height to handle fast scrolls.
        let maxSearchRows = min(next.height / 2, next.height - templateH)
        guard maxSearchRows > 0 else { return OverlapResult(overlapPx: 0, confidence: 0) }

        let searchRegionH = maxSearchRows + templateH
        guard let searchCG = next.cropping(to: CGRect(
            x: 0, y: 0, width: stripW, height: searchRegionH
        )) else { return OverlapResult(overlapPx: 0, confidence: 0) }

        guard let tBuf = cgImageToRGBA(templateCG),
              let sBuf = cgImageToRGBA(searchCG) else {
            return OverlapResult(overlapPx: 0, confidence: 0)
        }

        // Convert template bytes to Float once — only channels 0,1,2 (R,G,B; skip A)
        // We interleave all pixels, so stride by 4 and pick channels 0,1,2 per pixel.
        // For speed, sample every `colStride` columns.
        let colStride = max(1, stripW / 80)
        let sampledCols = stride(from: 0, to: stripW, by: colStride).map { $0 }
        let numSamples  = sampledCols.count * templateH * 3  // 3 colour channels

        var tFloat = [Float](repeating: 0, count: numSamples)
        var idx = 0
        for row in 0..<templateH {
            for col in sampledCols {
                let pix = (row * stripW + col) * 4
                tFloat[idx]     = Float(tBuf[pix])
                tFloat[idx + 1] = Float(tBuf[pix + 1])
                tFloat[idx + 2] = Float(tBuf[pix + 2])
                idx += 3
            }
        }

        var bestOffset = 0
        var bestSAD: Float = .infinity

        var sFloat = [Float](repeating: 0, count: numSamples)

        for candidateRow in 0..<maxSearchRows {
            var i2 = 0
            for row in 0..<templateH {
                for col in sampledCols {
                    let pix = ((candidateRow + row) * stripW + col) * 4
                    sFloat[i2]     = Float(sBuf[pix])
                    sFloat[i2 + 1] = Float(sBuf[pix + 1])
                    sFloat[i2 + 2] = Float(sBuf[pix + 2])
                    i2 += 3
                }
            }

            var diff = [Float](repeating: 0, count: numSamples)
            vDSP_vsub(sFloat, 1, tFloat, 1, &diff, 1, vDSP_Length(numSamples))
            var absDiff = diff
            vDSP_vabs(absDiff, 1, &absDiff, 1, vDSP_Length(numSamples))
            var sad: Float = 0
            vDSP_sve(absDiff, 1, &sad, vDSP_Length(numSamples))

            if sad < bestSAD {
                bestSAD = sad
                bestOffset = candidateRow
            }
        }

        // Normalise: expected max SAD if every channel differs by 30 grey levels
        let maxExpectedSAD = Float(numSamples) * 30.0
        let confidence = max(0, min(1, 1.0 - bestSAD / maxExpectedSAD))

        // If confidence is too low the content changed beyond recognition — append cleanly
        if confidence < 0.15 {
            return OverlapResult(overlapPx: 0, confidence: confidence)
        }

        // `bestOffset` = first row of `next` that matches the top of the template.
        // The overlap region in `next` starts at row `bestOffset` and spans `templateH` rows.
        // Total rows to skip from the top of `next` = bestOffset + templateH
        //   … but bestOffset already represents where the TEMPLATE starts in the search buf,
        //   which is the bottom of the overlap region as seen from `next`.
        // So the full overlap count = bestOffset + templateH (the entire matching band
        // plus everything above it that was already in `previous`).
        let totalOverlap = bestOffset + templateH

        return OverlapResult(overlapPx: totalOverlap, confidence: confidence)
    }

    // MARK: - Helpers

    private func cgImageToRGBA(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buf, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private func copyToCPUBacked(_ src: CGImage) -> CGImage? {
        let w = src.width, h = src.height
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - Deliver result

    private func deliverResult() {
        guard let cg = stitchedImage else {
            onSessionDone?(nil)
            return
        }
        let scale = screen.backingScaleFactor
        let ns = NSImage(cgImage: cg, size: CGSize(
            width:  CGFloat(cg.width)  / scale,
            height: CGFloat(cg.height) / scale
        ))
        onSessionDone?(ns)
    }
}
