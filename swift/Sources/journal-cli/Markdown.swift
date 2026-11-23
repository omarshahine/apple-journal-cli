// Markdown.swift — render a small Markdown subset into Journal's rich text.
//
// Journal stores entry text as RTF and renders formatting, but it does not
// understand Markdown: syntax left in the text shows up literally, so an
// imported "###### Reflect on today:" reads as exactly that. This turns the
// subset that actually appears in journal writing into the formatting
// Journal itself offers -- bold, italic, strikethrough, and real lists --
// and strips the rest.
//
// Deliberately not a full CommonMark implementation. Tables, images, nested
// lists, reference links and setext headings are out of scope; anything
// unrecognized survives as plain text rather than being mangled.
//
// Note on escapes: Day One writes "1\. text" when the author meant a literal
// "1." rather than a numbered list. Because list detection runs against the
// raw line, before unescaping, those correctly stay plain text.
import Foundation
import AppKit

private let BASE_SIZE: CGFloat = 12

private func rx(_ p: String) -> NSRegularExpression {
    guard let r = try? NSRegularExpression(pattern: p) else {
        die("bad internal markdown pattern")
    }
    return r
}

private let HEADING = rx("^[ \\t]{0,3}(#{1,6})[ \\t]+(.*)$")
private let RULE = rx("^[ \\t]*(?:-{3,}|\\*{3,}|_{3,})[ \\t]*$")
// An opening fence is optional indentation, three or more backticks or
// tildes, then an optional info string (a backtick fence's may not contain a
// backtick). Only a bare run of the same character, at least as long, closes
// the block, so "```literal" inside a block stays content and "~~~" does not
// close a backtick block.
private let FENCE_OPEN = rx("^[ \\t]*(`{3,}|~{3,})(.*)$")
private let FENCE_CLOSE = rx("^[ \\t]*(`{3,}|~{3,})[ \\t]*$")
// Image syntax is outside this subset and must survive as written: hidden
// whole before the emphasis passes, so "/_full_/" in its url stays intact.
// The destination is read whole: an <angle-bracket> form, or a url that may
// hold balanced parentheses ("a(b)/_full_/x.jpg"), as CommonMark allows.
// Label: one level of nested brackets. Destination: <...>, or up to two levels
// of balanced parentheses. Title: "...", '...' or (...), per CommonMark.
private let IMAGE = rx("!\\[(?:[^\\[\\]]|\\[[^\\[\\]]*\\])*\\]\\((?:<[^>\\n]*>|(?:[^()\\s]|\\((?:[^()\\s]|\\([^()\\s]*\\))*\\))+)(?:\\s+(?:\"[^\"]*\"|'[^']*'|\\([^()]*\\)))?\\)")

/// The fence run that opens a block on this line, or nil.
private func fenceOpen(_ line: String) -> String? {
    guard let run = capture(line, FENCE_OPEN, 1) else { return nil }
    if run.hasPrefix("`"), (capture(line, FENCE_OPEN, 2) ?? "").contains("`") { return nil }
    return run
}

/// Whether this line closes a block opened by `run`.
private func fenceCloses(_ line: String, _ run: String) -> Bool {
    guard let close = capture(line, FENCE_CLOSE, 1) else { return false }
    return close.first == run.first && close.count >= run.count
}
private let BULLET = rx("^[ \\t]{0,3}[-*+][ \\t]+(.*)$")
private let ORDERED = rx("^[ \\t]{0,3}[0-9]{1,9}[.)][ \\t]+(.*)$")
private let QUOTE = rx("^[ \\t]{0,3}>[ \\t]?(.*)$")
// The negative lookbehind keeps image syntax out: "![alt](url)" is outside
// this subset, so it survives as written rather than becoming "!alt (url)".
private let LINK = rx("(?<!!)\\[([^\\]]*)\\]\\(([^)\\s]+)(?:\\s+\"[^\"]*\")?\\)")
private let TRIPLE_STAR = rx("\\*\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*\\*")
private let TRIPLE_UNDER = rx("(?<![\\w_])___(?=\\S)(.+?)(?<=\\S)___(?![\\w_])")
private let STRONG_STAR = rx("\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*")
// Underscores need flanking rules that asterisks do not: "foo__bar__baz" is
// an identifier, not emphasis.
private let STRONG_UNDER = rx("(?<![\\w_])__(?=\\S)(.+?)(?<=\\S)__(?![\\w_])")
private let STRIKE = rx("(~~)(?=\\S)(.+?)(?<=\\S)\\1")
private let EMPH = rx("(?<![\\w*_])([*_])(?=\\S)([^*_]+?)(?<=\\S)\\1(?![\\w*_])")
// Characters Markdown lets you escape. An escaped delimiter must survive
// emphasis parsing intact -- "\\*literal\\*" is a literal asterisk pair, not
// italics -- so each one is swapped for a private-use codepoint before the
// emphasis regexes run and swapped back afterwards.
// The C0 controls U+0001...U+0008 are hidden the same way, unconditionally:
// they are this file's own emphasis and link markers, and a literal one in
// the input would otherwise end (or start) formatting early.
// Scalars, not Characters: "*" followed by a combining accent is one
// Character, and comparing whole graphemes would miss the escaped "*".
private let CONTROLS: [Unicode.Scalar] = (1...8).map { Unicode.Scalar(UInt8($0)) }
private let ESCAPABLE: [Unicode.Scalar] = Array("\\`*_{}[]()#+-.!>~|".unicodeScalars) + CONTROLS

/// Pick a private-use window this text does not already use, so a literal
/// private-use character in someone's entry is never mistaken for our own
/// sentinel and rewritten as punctuation. The BMP block is tried first, then
/// the two supplementary private-use planes; a line would need well over a
/// hundred thousand distinct private-use characters to occupy every window,
/// and then the render is refused rather than any character reinterpreted.
private let PRIVATE_USE: [ClosedRange<UInt32>] = [0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD]

private func escapeBase(for s: String) -> UInt32 {
    let width = UInt32(ESCAPABLE.count)
    let used = Set(s.unicodeScalars.map { $0.value }
        .filter { v in PRIVATE_USE.contains { $0.contains(v) } })
    if used.isEmpty { return 0xE000 }
    for block in PRIVATE_USE {
        var base = block.lowerBound
        while base + width - 1 <= block.upperBound {
            if !(base..<(base + width)).contains(where: { used.contains($0) }) { return base }
            base += width
        }
    }
    die("text uses every private-use window markdown escaping needs; "
        + "pass it without --markdown")
}

// One pass over the line, so precedence is explicit: a backslash escape makes
// the next scalar inert, a backtick opens a code span whose contents are
// taken verbatim (escapes included), and both are hidden in the private-use
// range where the emphasis regexes cannot see them. Everything works on
// Unicode scalars: an escaped "*" followed by a combining mark is one
// Character, and must still read as an escape (the mark stays after it).
private func protectInline(_ s: String, _ base: UInt32) -> String {
    var out = String.UnicodeScalarView()
    var escaping = false
    var inCode = false
    var code = String.UnicodeScalarView()
    func hide(_ u: Unicode.Scalar) {
        if let i = ESCAPABLE.firstIndex(of: u),
           let scalar = Unicode.Scalar(base + UInt32(i)) {
            out.append(scalar)
        } else {
            // Markdown only escapes its own punctuation; a backslash before
            // anything else is literal text, as in a Windows path.
            out.append("\\")
            out.append(u)
        }
    }
    for u in s.unicodeScalars {
        if inCode {
            if u == "`" {
                out.append(contentsOf: hideAll("`" + String(code) + "`", base).unicodeScalars)
                inCode = false
                code = String.UnicodeScalarView()
            } else {
                code.append(u)
            }
            continue
        }
        if escaping {
            hide(u)
            escaping = false
        } else if u == "\\" {
            escaping = true
        } else if u == "`" {
            inCode = true
            code = String.UnicodeScalarView()
        } else if CONTROLS.contains(u) {
            hide(u)
        } else {
            out.append(u)
        }
    }
    if inCode {                            // unterminated span stays literal
        out.append(contentsOf: hideAll("`" + String(code), base).unicodeScalars)
    }
    if escaping { out.append("\\") }        // a trailing lone backslash
    return String(out)
}

/// Map every escapable scalar in a string onto the private-use range.
private func hideAll(_ s: String, _ base: UInt32) -> String {
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
        if let i = ESCAPABLE.firstIndex(of: u),
           let scalar = Unicode.Scalar(base + UInt32(i)) {
            out.append(scalar)
        } else {
            out.append(u)
        }
    }
    return String(out)
}

/// Undo hideAll/protectInline scalar by scalar, so a sentinel that a combining
/// mark joined into one grapheme is still restored.
private func restoreEscapes(_ s: String, _ base: UInt32) -> String {
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
        let v = u.value
        if v >= base, v < base + UInt32(ESCAPABLE.count) {
            out.append(ESCAPABLE[Int(v - base)])
        } else {
            out.append(u)
        }
    }
    return String(out)
}

private func sub(_ s: String, _ re: NSRegularExpression, _ tmpl: String) -> String {
    re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                withTemplate: tmpl)
}

private func capture(_ s: String, _ re: NSRegularExpression, _ group: Int) -> String? {
    guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          let r = Range(m.range(at: group), in: s) else { return nil }
    return String(s[r])
}

private func hits(_ s: String, _ re: NSRegularExpression) -> Bool {
    re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

private struct Span {
    var text: String
    var bold = false
    var italic = false
    var strike = false
}

private enum LineKind: Equatable {
    case body
    case code      // a fenced line: literal, never collapsed or trimmed
    case bullet
    case ordered
    case quote
}

/// Pull inline emphasis out of a line, leaving styled spans behind.
private func inlineSpans(_ line: String, forceBold: Bool) -> [Span] {
    let base = escapeBase(for: line)
    var s = protectInline(line, base)
    // Hide whole image constructs before links and emphasis see them.
    for m in IMAGE.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
        guard let r = Range(m.range, in: s) else { continue }
        s.replaceSubrange(r, with: hideAll(String(s[r]), base))
    }

    // "[text](url)" -> "text (url)", or just the url when the label adds nothing.
    // The url goes in as an opaque marker so the emphasis passes below cannot
    // read its "*" or "_" as formatting; the label is still parsed.
    var urls: [String] = []
    while let m = LINK.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
        guard let whole = Range(m.range, in: s) else { break }
        let label = Range(m.range(at: 1), in: s).map { String(s[$0]) } ?? ""
        let url = Range(m.range(at: 2), in: s).map { String(s[$0]) } ?? ""
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let marker = "\u{4}\(urls.count)\u{5}"
        urls.append(url)
        s.replaceSubrange(whole, with: trimmed.isEmpty || trimmed == url
                          ? marker : "\(trimmed) (\(marker))")
    }
    func unmark(_ t: String) -> String {
        guard !urls.isEmpty else { return t }
        var out = t
        for (i, u) in urls.enumerated().reversed() {
            out = out.replacingOccurrences(of: "\u{4}\(i)\u{5}", with: u)
        }
        return out
    }

    // Mark emphasis with sentinels so the spans survive unescaping. Opening
    // and closing marks differ, and each style counts its depth: a single
    // toggle would turn bold OFF at the inner "__" of "**a __b__ c**".
    let B = "\u{1}", I = "\u{2}", S = "\u{3}"           // open
    let b = "\u{6}", i = "\u{7}", z = "\u{8}"           // close
    // Triple delimiters first: otherwise the strong pass eats two and the
    // emphasis pass eats the rest, losing bold from "***both***".
    s = sub(s, TRIPLE_STAR, "\(B)\(I)$1\(i)\(b)")
    s = sub(s, TRIPLE_UNDER, "\(B)\(I)$1\(i)\(b)")
    s = sub(s, STRONG_STAR, "\(B)$1\(b)")
    s = sub(s, STRONG_UNDER, "\(B)$1\(b)")
    s = sub(s, STRIKE, "\(S)$2\(z)")
    s = sub(s, EMPH, "\(I)$2\(i)")

    var spans: [Span] = []
    var cur = ""
    var boldDepth = 0, italicDepth = 0, strikeDepth = 0
    var bold: Bool { boldDepth > 0 }
    var italic: Bool { italicDepth > 0 }
    var strike: Bool { strikeDepth > 0 }
    func flush() {
        if !cur.isEmpty {
            spans.append(Span(text: restoreEscapes(unmark(cur), base), bold: bold || forceBold,
                              italic: italic, strike: strike))
            cur = ""
        }
    }
    for ch in s {
        switch ch {
        case "\u{1}": flush(); boldDepth += 1
        case "\u{6}": flush(); boldDepth = max(0, boldDepth - 1)
        case "\u{2}": flush(); italicDepth += 1
        case "\u{7}": flush(); italicDepth = max(0, italicDepth - 1)
        case "\u{3}": flush(); strikeDepth += 1
        case "\u{8}": flush(); strikeDepth = max(0, strikeDepth - 1)
        default: cur.append(ch)
        }
    }
    flush()
    return spans
}

private func font(_ sp: Span) -> NSFont {
    var f = sp.bold ? NSFont.boldSystemFont(ofSize: BASE_SIZE)
                    : NSFont.systemFont(ofSize: BASE_SIZE)
    if sp.italic {
        f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
    }
    return f
}

private func listStyle(_ format: NSTextList.MarkerFormat) -> (NSTextList, NSParagraphStyle) {
    let list = NSTextList(markerFormat: format, options: 0)
    let ps = NSMutableParagraphStyle()
    ps.textLists = [list]
    ps.headIndent = 24
    ps.firstLineHeadIndent = 12
    return (list, ps)
}

private let quoteStyle: NSParagraphStyle = {
    let ps = NSMutableParagraphStyle()
    ps.headIndent = 24
    ps.firstLineHeadIndent = 24
    return ps
}()

/// Render Markdown into an attributed string using Journal's body font.
func markdownToAttributed(_ md: String) -> NSAttributedString {
    var kinds: [LineKind] = []
    var contents: [[Span]] = []
    var fence = ""                         // the opening run; "" = not in a block

    // CRLF must not split twice: .newlines treats \r and \n as separate
    // delimiters, which would insert a blank line after every source line.
    let normalized = md.replacingOccurrences(of: "\r\n", with: "\n")
                       .replacingOccurrences(of: "\r", with: "\n")
    for raw in normalized.components(separatedBy: "\n") {
        if !fence.isEmpty {
            if fenceCloses(raw, fence) {
                fence = ""; continue
            }
            kinds.append(.code)
            contents.append([Span(text: raw)])
            continue
        }
        if let run = fenceOpen(raw) { fence = run; continue }
        if hits(raw, RULE) { continue }            // a rule has no text form

        if let text = capture(raw, HEADING, 2) {
            kinds.append(.body)
            contents.append(inlineSpans(text, forceBold: true))
        } else if let text = capture(raw, BULLET, 1) {
            kinds.append(.bullet)
            contents.append(inlineSpans(text, forceBold: false))
        } else if let text = capture(raw, ORDERED, 1) {
            kinds.append(.ordered)
            contents.append(inlineSpans(text, forceBold: false))
        } else if let text = capture(raw, QUOTE, 1) {
            kinds.append(.quote)
            contents.append(inlineSpans(text, forceBold: false))
        } else {
            kinds.append(.body)
            contents.append(inlineSpans(raw, forceBold: false))
        }
    }

    let out = NSMutableAttributedString()
    let plain = NSFont.systemFont(ofSize: BASE_SIZE)
    var blanks = 0
    var index = 0
    var codeEnd = 0                         // out.length just after the last code line

    while index < kinds.count {
        let kind = kinds[index]

        if kind == .bullet || kind == .ordered {
            // Consecutive items of one kind form a single list, numbered from 1.
            let (list, style) = listStyle(kind == .ordered ? .decimal : .disc)
            var item = 0
            while index < kinds.count, kinds[index] == kind {
                item += 1
                let marker = list.marker(forItemNumber: item)
                out.append(NSAttributedString(string: "\t\(marker)\t",
                    attributes: [.font: plain, .paragraphStyle: style]))
                for sp in contents[index] {
                    var attrs: [NSAttributedString.Key: Any] =
                        [.font: font(sp), .paragraphStyle: style]
                    if sp.strike { attrs[.strikethroughStyle] = 1 }
                    out.append(NSAttributedString(string: sp.text, attributes: attrs))
                }
                out.append(NSAttributedString(string: "\n",
                    attributes: [.font: plain, .paragraphStyle: style]))
                index += 1
            }
            blanks = 0
            continue
        }

        let spans = contents[index]
        index += 1
        if kind == .code {
            // Fenced content is literal: blank and whitespace-only lines stay
            // exactly as written, so the prose blank-collapsing below must not
            // see them.
            out.append(NSAttributedString(string: spans.map(\.text).joined() + "\n",
                                          attributes: [.font: plain]))
            codeEnd = out.length
            blanks = 0
            continue
        }
        if spans.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            // Collapse runs of blanks left behind by dropped rules.
            blanks += 1
            if blanks > 1 || out.length == 0 { continue }
            out.append(NSAttributedString(string: "\n", attributes: [.font: plain]))
            continue
        }
        blanks = 0
        let style: NSParagraphStyle? = kind == .quote ? quoteStyle : nil
        for sp in spans {
            var attrs: [NSAttributedString.Key: Any] = [.font: font(sp)]
            if sp.strike { attrs[.strikethroughStyle] = 1 }
            if let style = style { attrs[.paragraphStyle] = style }
            out.append(NSAttributedString(string: sp.text, attributes: attrs))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: plain]))
    }

    // Trim trailing newlines, but not into a final fenced block: only its last
    // line's terminator goes, so blank lines it ends with stay.
    while out.length > max(codeEnd - 1, 0), out.string.hasSuffix("\n") {
        out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
    }
    return out
}

/// Markdown -> (RTF for ZTEXT, plain text for length and emptiness checks).
func markdownToRTF(_ md: String) -> (data: Data, plain: String) {
    let att = markdownToAttributed(md)
    guard let d = att.rtf(from: NSRange(location: 0, length: att.length),
                          documentAttributes: [:]) else {
        die("could not build RTF from markdown")
    }
    // Decode the plain half with rtfToText -- the same function every read
    // path uses -- so ZTEXTLENGTH and the emptiness check describe exactly
    // what `show` will return. Doing it any other way drifts: generated list
    // markers survive the round trip on some macOS releases but not others,
    // and rtfToText trims surrounding whitespace.
    return (d, rtfToText(d))
}

/// The text as it reads once stored: rendering to RTF and parsing back drops
/// generated list marker runs, so this is what a reader of the saved entry
/// actually sees. Comparing anything else against a stored entry compares
/// two different things.
func markdownToPlain(_ md: String) -> String {
    let att = markdownToAttributed(md)
    guard let d = att.rtf(from: NSRange(location: 0, length: att.length),
                          documentAttributes: [:]) else {
        return att.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return rtfToText(d)
}

/// Inline-only stripping, for single-line fields such as the title. Block
/// syntax must not apply there: a title of "1. first" is a title, not a list
/// item, and "---" is a title, not a horizontal rule.
func markdownToInlinePlain(_ md: String) -> String {
    let lines = md.replacingOccurrences(of: "\r\n", with: "\n")
                  .replacingOccurrences(of: "\r", with: "\n")
                  .components(separatedBy: "\n")
    return lines
        .map { inlineSpans($0, forceBold: false).map { $0.text }.joined() }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
