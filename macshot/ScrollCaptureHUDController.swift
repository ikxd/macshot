import Cocoa

/// A small non-intrusive floating panel that overlays the screen during a scroll-capture
/// session. Shows live strip count, a growing thumbnail of the stitched result, and a
/// Stop button. The panel is anchored to the right (or left if near the screen edge)
/// of the capture selection so it never covers the captured content.
final class ScrollCaptureHUDController {

    private var panel: NSPanel?
    private weak var previewView: NSImageView?
    private weak var statsLabel:  NSTextField?
    private weak var stopButton:  NSButton?

    private let screen: NSScreen

    var onStop: (() -> Void)?

    // MARK: - Init

    init(selectionRectScreen: NSRect, screen: NSScreen) {
        self.screen = screen
        buildPanel(selectionRectScreen: selectionRectScreen)
    }

    // MARK: - Build

    private func buildPanel(selectionRectScreen: NSRect) {
        let panelW: CGFloat = 210
        let panelH: CGFloat = 136

        // Position to the right of the selection; fall back to left if it would overflow.
        let gap: CGFloat = 12
        var panelX = selectionRectScreen.maxX + gap
        if panelX + panelW > screen.frame.maxX - 8 {
            panelX = selectionRectScreen.minX - panelW - gap
        }
        // Clamp inside screen
        panelX = max(screen.frame.minX + 8, min(panelX, screen.frame.maxX - panelW - 8))

        // Vertically centred on selection, clamped to screen
        var panelY = selectionRectScreen.midY - panelH / 2
        panelY = max(screen.frame.minY + 8, min(panelY, screen.frame.maxY - panelH - 8))

        let p = NSPanel(
            contentRect: NSRect(x: panelX, y: panelY, width: panelW, height: panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let root = HUDRootView(frame: NSRect(origin: .zero, size: CGSize(width: panelW, height: panelH)))
        p.contentView = root

        let pad: CGFloat = 10

        // Title row
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "scroll", accessibilityDescription: nil)
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 14).isActive  = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let title = NSTextField(labelWithString: "Scroll Capture")
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView(views: [icon, title])
        titleRow.orientation  = .horizontal
        titleRow.spacing      = 5
        titleRow.alignment    = .centerY
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        // Preview thumbnail
        let preview = NSImageView()
        preview.imageScaling  = .scaleProportionallyUpOrDown
        preview.imageFrameStyle = .none
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 4
        preview.layer?.masksToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        self.previewView = preview

        // Stats label
        let stats = NSTextField(labelWithString: "Strips: 1")
        stats.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        stats.textColor = NSColor.white.withAlphaComponent(0.65)
        stats.translatesAutoresizingMaskIntoConstraints = false
        stats.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.statsLabel = stats

        // Stop button
        let btn = NSButton(title: "  Stop  ", target: self, action: #selector(stopTapped))
        btn.bezelStyle    = .rounded
        btn.isBordered    = false
        btn.wantsLayer    = true
        btn.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        btn.layer?.cornerRadius    = 5
        btn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        btn.attributedTitle = NSAttributedString(
            string: "Stop",
            attributes: [.foregroundColor: NSColor.white,
                         .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
        )
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
        self.stopButton = btn

        let bottomRow = NSStackView(views: [stats, btn])
        bottomRow.orientation = .horizontal
        bottomRow.spacing     = 6
        bottomRow.alignment   = .centerY
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(titleRow)
        root.addSubview(preview)
        root.addSubview(bottomRow)

        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            titleRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -pad),

            preview.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 8),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            preview.heightAnchor.constraint(equalToConstant: 46),

            bottomRow.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 8),
            bottomRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            bottomRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            bottomRow.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -pad),
        ])

        self.panel = p
    }

    // MARK: - Lifecycle

    func show() {
        panel?.orderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    // MARK: - Update

    func update(stripCount: Int, stitchedImage: CGImage?, pixelSize: CGSize) {
        let scale = screen.backingScaleFactor
        let ptW = Int(pixelSize.width  / scale)
        let ptH = Int(pixelSize.height / scale)

        statsLabel?.stringValue = "Strips: \(stripCount)  ·  \(ptW) × \(ptH) pt"

        if let cg = stitchedImage {
            previewView?.image = NSImage(cgImage: cg, size: .zero)
        }
    }

    // MARK: - Actions

    @objc private func stopTapped() {
        onStop?()
    }
}

// MARK: - HUDRootView (draws the dark rounded background)

private final class HUDRootView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor(white: 0.12, alpha: 0.94).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.08).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    override var isFlipped: Bool { false }
}
