import Cocoa

/// Manages inline text editing for the text annotation tool.
/// Owns the text style state, NSTextView lifecycle, and font management.
class TextEditingController {

    // MARK: - Text style state

    var fontSize: CGFloat = UserDefaults.standard.object(forKey: "textFontSize") as? CGFloat ?? 20
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false
    var alignment: NSTextAlignment = .left
    var fontFamily: String = UserDefaults.standard.string(forKey: "textFontFamily") ?? "System"
    var bgEnabled: Bool = UserDefaults.standard.bool(forKey: "textBgEnabled")
    var outlineEnabled: Bool = UserDefaults.standard.bool(forKey: "textOutlineEnabled")

    var bgColor: NSColor = {
        if let data = UserDefaults.standard.data(forKey: "textBgColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) { return color }
        return NSColor.black.withAlphaComponent(0.5)
    }()

    var outlineColor: NSColor = {
        if let data = UserDefaults.standard.data(forKey: "textOutlineColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) { return color }
        return NSColor.white
    }()

    // MARK: - NSTextView

    private(set) var textView: NSTextView?
    private(set) var scrollView: NSScrollView?

    var isEditing: Bool { textView != nil }

    // MARK: - Font list

    static let fontFamilies: [String] = {
        var families = ["System"]
        families.append(contentsOf: NSFontManager.shared.availableFontFamilies.sorted())
        return families
    }()

    // MARK: - Font construction

    func currentFont() -> NSFont {
        let baseFont: NSFont
        if fontFamily == "System" {
            baseFont = NSFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
        } else {
            baseFont = NSFont(name: fontFamily, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        }
        return applyTraits(to: baseFont)
    }

    private func applyTraits(to font: NSFont) -> NSFont {
        var result = font
        if bold {
            result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask)
        }
        if italic {
            result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask)
        }
        return result
    }

    // MARK: - Style toggles

    func toggleBold() {
        bold.toggle()
        applyStyleToLiveText()
    }

    func toggleItalic() {
        italic.toggle()
        applyStyleToLiveText()
    }

    func toggleUnderline() {
        underline.toggle()
        applyUnderlineToLiveText()
    }

    func toggleStrikethrough() {
        strikethrough.toggle()
        applyStrikethroughToLiveText()
    }

    func applyFontSizeChange() {
        guard let tv = textView else { return }
        let range = tv.selectedRange().length > 0 ? tv.selectedRange() : NSRange(location: 0, length: tv.textStorage?.length ?? 0)
        tv.textStorage?.addAttribute(.font, value: currentFont(), range: range)
    }

    func applyAlignment() {
        guard let tv = textView else { return }
        let range = NSRange(location: 0, length: tv.textStorage?.length ?? 0)
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        tv.textStorage?.addAttribute(.paragraphStyle, value: style, range: range)
    }

    func applyColorToLiveText(color: NSColor) {
        guard let tv = textView else { return }
        let range = tv.selectedRange().length > 0 ? tv.selectedRange() : NSRange(location: 0, length: tv.textStorage?.length ?? 0)
        tv.textStorage?.addAttribute(.foregroundColor, value: color, range: range)
    }

    // MARK: - Create/Destroy text view

    func createTextView(in parentView: NSView, at point: NSPoint, color: NSColor, existingText: NSAttributedString? = nil, existingFrame: NSRect = .zero) {
        dismiss()

        let minW: CGFloat = 120
        let minH: CGFloat = 30
        let frame: NSRect
        if existingFrame != .zero {
            frame = existingFrame
        } else {
            frame = NSRect(x: point.x, y: point.y - minH / 2, width: minW, height: minH)
        }

        let sv = NSScrollView(frame: frame)
        sv.hasVerticalScroller = false
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.borderType = .noBorder

        let tv = NSTextView(frame: NSRect(origin: .zero, size: frame.size))
        tv.isRichText = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.textContainer?.containerSize = NSSize(width: frame.width - 8, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true

        let font = currentFont()
        tv.font = font
        tv.textColor = color
        tv.insertionPointColor = color

        if let existing = existingText {
            tv.textStorage?.setAttributedString(existing)
        } else {
            tv.typingAttributes = [
                .font: font,
                .foregroundColor: color,
            ]
        }

        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        let range = NSRange(location: 0, length: tv.textStorage?.length ?? 0)
        tv.textStorage?.addAttribute(.paragraphStyle, value: style, range: range)

        sv.documentView = tv
        parentView.addSubview(sv)

        self.scrollView = sv
        self.textView = tv

        parentView.window?.makeFirstResponder(tv)
    }

    func dismiss() {
        scrollView?.removeFromSuperview()
        scrollView = nil
        textView = nil
    }

    /// Collect the current text content as an attributed string and frame rect for annotation storage.
    func collectContent() -> (attributedText: NSAttributedString, frame: NSRect)? {
        guard let tv = textView, let sv = scrollView,
              let storage = tv.textStorage, storage.length > 0 else { return nil }
        return (storage.copy() as! NSAttributedString, sv.frame)
    }

    // MARK: - Private style helpers

    private func applyStyleToLiveText() {
        guard let tv = textView else { return }
        let range = tv.selectedRange().length > 0 ? tv.selectedRange() : NSRange(location: 0, length: tv.textStorage?.length ?? 0)
        tv.textStorage?.addAttribute(.font, value: currentFont(), range: range)
        tv.typingAttributes[.font] = currentFont()
    }

    private func applyUnderlineToLiveText() {
        guard let tv = textView else { return }
        let range = tv.selectedRange().length > 0 ? tv.selectedRange() : NSRange(location: 0, length: tv.textStorage?.length ?? 0)
        if underline {
            tv.textStorage?.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        } else {
            tv.textStorage?.removeAttribute(.underlineStyle, range: range)
        }
    }

    private func applyStrikethroughToLiveText() {
        guard let tv = textView else { return }
        let range = tv.selectedRange().length > 0 ? tv.selectedRange() : NSRange(location: 0, length: tv.textStorage?.length ?? 0)
        if strikethrough {
            tv.textStorage?.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        } else {
            tv.textStorage?.removeAttribute(.strikethroughStyle, range: range)
        }
    }
}
