import AppKit
import SwiftUI

/// Plain-text Markdown editor with live styling (the text stays Markdown; only its
/// appearance changes). Supports smart list continuation and clickable `- [ ]` boxes.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    /// Reports the laid-out text height so the notch can size itself to the note.
    var onHeightChange: (CGFloat) -> Void
    var focusOnAppear = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let tv = MarkdownTextView()
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.insertionPointColor = .white
        tv.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.22)]
        tv.typingAttributes = MarkdownStyler.baseAttributes
        tv.string = text
        MarkdownStyler.apply(to: tv)

        scroll.documentView = tv
        context.coordinator.textView = tv
        tv.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged),
                                               name: NSView.frameDidChangeNotification, object: tv)
        DispatchQueue.main.async {
            if focusOnAppear { tv.window?.makeFirstResponder(tv) }
            context.coordinator.reportHeight()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView, tv.string != text else { return }
        tv.string = text
        MarkdownStyler.apply(to: tv)
        context.coordinator.reportHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: MarkdownTextView?
        private var lastHeight: CGFloat = -1

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            MarkdownStyler.apply(to: tv)
            parent.text = tv.string
            reportHeight()
        }

        @objc func frameChanged() { reportHeight() }

        func reportHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height + tv.textContainerInset.height * 2)
            guard abs(h - lastHeight) > 0.5 else { return }
            lastHeight = h
            let report = parent.onHeightChange
            DispatchQueue.main.async { report(h) } // never publish during a view update
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                return MarkdownStyler.continueList(in: textView)
            }
            return false
        }
    }
}

/// Text view that toggles `- [ ]` / `- [x]` when the box is clicked.
final class MarkdownTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if MarkdownStyler.toggleCheckbox(in: self, at: index) { return }
        super.mouseDown(with: event)
    }

    // Pointing-hand cursor over checkboxes.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if MarkdownStyler.checkboxRange(in: string as NSString, at: index) != nil { NSCursor.pointingHand.set() }
    }
}

enum MarkdownStyler {
    static let fontSize: CGFloat = 13
    static let baseFont = NSFont.systemFont(ofSize: fontSize)
    static let textColor = NSColor.white.withAlphaComponent(0.92)
    static let syntaxColor = NSColor.white.withAlphaComponent(0.28)
    static let markerColor = NSColor.white.withAlphaComponent(0.5)
    static let linkColor = NSColor(red: 0.45, green: 0.68, blue: 1, alpha: 1)

    static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacing = 2
        return p
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: textColor, .paragraphStyle: paragraph]
    }

    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines])
    }

    private static let heading = re(#"^(#{1,3})[ \t]+.*$"#)
    private static let quote = re(#"^(>)[ \t]?.*$"#)
    private static let task = re(#"^([ \t]*[-*+] )\[([ xX])\](.*)$"#)
    private static let bullet = re(#"^([ \t]*)([-*+]|\d+\.)[ \t]"#)
    private static let rule = re(#"^(?:-{3,}|\*{3,})[ \t]*$"#)
    private static let code = re(#"(`)([^`\n]+)(`)"#)
    private static let bold = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = re(#"(?<![*_\w])([*_])(?=\S)([^*_\n]+?)(?<=\S)\1(?![*_\w])"#)
    private static let strike = re(#"(~~)(?=\S)(.+?)(?<=\S)~~"#)
    private static let link = re(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)

    /// Re-styles the whole document (attributes only; text and selection are untouched).
    static func apply(to tv: NSTextView) {
        guard let ts = tv.textStorage else { return }
        let s = ts.string as NSString
        let full = NSRange(location: 0, length: s.length)
        ts.beginEditing()
        ts.setAttributes(baseAttributes, range: full)

        heading.enumerateMatches(in: ts.string, range: full) { m, _, _ in
            guard let m else { return }
            let level = m.range(at: 1).length
            let size: CGFloat = [19, 16, 14][level - 1]
            ts.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: m.range)
            ts.addAttribute(.foregroundColor, value: syntaxColor, range: m.range(at: 1))
        }
        quote.enumerateMatches(in: ts.string, range: full) { m, _, _ in
            guard let m else { return }
            ts.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.6), range: m.range)
            ts.addAttribute(.foregroundColor, value: markerColor, range: m.range(at: 1))
        }
        bullet.enumerateMatches(in: ts.string, range: full) { m, _, _ in
            guard let m else { return }
            ts.addAttribute(.foregroundColor, value: markerColor, range: m.range(at: 2))
        }
        task.enumerateMatches(in: ts.string, range: full) { m, _, _ in
            guard let m else { return }
            let box = NSRange(location: m.range(at: 2).location - 1, length: 3)
            let checked = s.substring(with: m.range(at: 2)).lowercased() == "x"
            ts.addAttribute(.foregroundColor, value: checked ? NSColor.systemGreen : markerColor, range: box)
            ts.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .semibold), range: box)
            if checked {
                ts.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.4), range: m.range(at: 3))
                ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 3))
            }
        }
        rule.enumerateMatches(in: ts.string, range: full) { m, _, _ in
            guard let m else { return }
            ts.addAttribute(.foregroundColor, value: syntaxColor, range: m.range)
        }
        bold.enumerateMatches(in: ts.string, range: full) { m, _, _ in
            guard let m else { return }
            addTrait(.boldFontMask, ts, m.range)
            dimDelimiters(ts, m, len: m.range(at: 1).length)
        }
        italic.enumerateMatches(in: ts.string, range: full) { m, _, _ in
            guard let m else { return }
            addTrait(.italicFontMask, ts, m.range)
            dimDelimiters(ts, m, len: 1)
        }
        strike.enumerateMatches(in: ts.string, range: full) { m, _, _ in
            guard let m else { return }
            ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
            dimDelimiters(ts, m, len: 2)
        }
        code.enumerateMatches(in: ts.string, range: full) { m, _, _ in
            guard let m else { return }
            ts.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular), range: m.range)
            ts.addAttribute(.backgroundColor, value: NSColor.white.withAlphaComponent(0.09), range: m.range(at: 2))
            ts.addAttribute(.foregroundColor, value: NSColor(red: 1, green: 0.72, blue: 0.55, alpha: 1), range: m.range(at: 2))
            ts.addAttribute(.foregroundColor, value: syntaxColor, range: m.range(at: 1))
            ts.addAttribute(.foregroundColor, value: syntaxColor, range: m.range(at: 3))
        }
        link.enumerateMatches(in: ts.string, range: full) { m, _, _ in
            guard let m else { return }
            ts.addAttribute(.foregroundColor, value: syntaxColor, range: m.range)
            ts.addAttribute(.foregroundColor, value: linkColor, range: m.range(at: 1))
        }
        ts.endEditing()
        tv.typingAttributes = baseAttributes
    }

    private static func addTrait(_ trait: NSFontTraitMask, _ ts: NSTextStorage, _ range: NSRange) {
        ts.enumerateAttribute(.font, in: range) { value, sub, _ in
            let font = (value as? NSFont) ?? baseFont
            ts.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: sub)
        }
    }

    private static func dimDelimiters(_ ts: NSTextStorage, _ m: NSTextCheckingResult, len: Int) {
        ts.addAttribute(.foregroundColor, value: syntaxColor, range: NSRange(location: m.range.location, length: len))
        ts.addAttribute(.foregroundColor, value: syntaxColor,
                        range: NSRange(location: NSMaxRange(m.range) - len, length: len))
    }

    // MARK: Checkboxes

    /// Range of the `[ ]` / `[x]` box near `index`, if the line is a task item.
    static func checkboxRange(in s: NSString, at index: Int) -> NSRange? {
        guard s.length > 0 else { return nil }
        let line = s.lineRange(for: NSRange(location: min(index, s.length - 1), length: 0))
        guard let m = task.firstMatch(in: s as String, range: line) else { return nil }
        let box = NSRange(location: m.range(at: 2).location - 1, length: 3)
        // Accept clicks on the box or right next to it.
        return (box.location - 1...NSMaxRange(box) + 1).contains(index) ? box : nil
    }

    static func toggleCheckbox(in tv: NSTextView, at index: Int) -> Bool {
        let s = tv.string as NSString
        guard let box = checkboxRange(in: s, at: index) else { return false }
        let mark = NSRange(location: box.location + 1, length: 1)
        let new = s.substring(with: mark) == " " ? "x" : " "
        guard tv.shouldChangeText(in: mark, replacementString: new) else { return true }
        tv.textStorage?.replaceCharacters(in: mark, with: new)
        tv.didChangeText() // undo + delegate (restyle, save)
        return true
    }

    // MARK: Lists

    private static let listItem = re(#"^([ \t]*)([-*+] \[[ xX]\] |[-*+] |(\d+)\. )(.*)$"#)

    /// Return key: continue the list item, or end the list on an empty item.
    static func continueList(in tv: NSTextView) -> Bool {
        let s = tv.string as NSString
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let line = s.lineRange(for: NSRange(location: sel.location, length: 0))
        var content = NSRange(location: line.location, length: line.length)
        if content.length > 0, s.substring(with: NSRange(location: NSMaxRange(content) - 1, length: 1)) == "\n" {
            content.length -= 1
        }
        guard let m = listItem.firstMatch(in: s as String, range: content) else { return false }
        let indent = s.substring(with: m.range(at: 1))
        let rest = s.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)

        if rest.isEmpty {
            // Empty item: remove the marker instead of adding another one.
            let marker = NSRange(location: content.location, length: NSMaxRange(m.range(at: 2)) - content.location)
            tv.insertText("", replacementRange: marker)
            return true
        }
        var marker = s.substring(with: m.range(at: 2))
        if m.range(at: 3).location != NSNotFound, let n = Int(s.substring(with: m.range(at: 3))) {
            marker = "\(n + 1). "
        } else if marker.contains("[") {
            marker = String(marker.prefix(2)) + "[ ] "
        }
        tv.insertText("\n" + indent + marker, replacementRange: sel)
        return true
    }
}
