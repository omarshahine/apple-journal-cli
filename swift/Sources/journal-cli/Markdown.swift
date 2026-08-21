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
private let FENCE = rx("^[ \\t]*```")
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
private let ESCAPABLE = Array("\\`*_{}[]()#+-.!>~|")

/// Pick a private-use window this text does not already use, so a literal
/// U+E000 in someone's entry is never mistaken for our own sentinel and
/// rewritten as punctuation.
private func escapeBase(for s: String) -> UInt32 {
    let width = UInt32(ESCAPABLE.count)
    let used = Set(s.unicodeScalars.map { $0.value }.filter { $0 >= 0xE000 && $0 <= 0xF8FF })
    if used.isEmpty { return 0xE000 }
    var base: UInt32 = 0xE000
    while base + width <= 0xF8FF {
        if !(base..<(base + width)).contains(where: { used.contains($0) }) { return base }
        base += width
    }
    return 0xE000
}

// One pass over the line, so precedence is explicit: a backslash escape makes
// the next character inert, a backtick opens a code span whose contents are
// taken verbatim (escapes included), and both are hidden in the private-use
// range where the emphasis regexes cannot see them.
private func protectInline(_ s: String, _ base: UInt32) -> String {
    var out = ""
    var escaping = false
    var inCode = false
    var code = ""
    func hide(_ ch: Character) {
        if let i = ESCAPABLE.firstIndex(of: ch),
           let scalar = Unicode.Scalar(base + UInt32(i)) {
            out.unicodeScalars.append(scalar)
        } else {
            // Markdown only escapes its own punctuation; a backslash before
            // anything else is literal text, as in a Windows path.
            out.append("\\")
            out.append(ch)
        }
    }
    for ch in s {
        if inCode {
            if ch == "`" {
                out.append(hideAll("`" + code + "`", base))
                inCode = false
                code = ""
            } else {
                code.append(ch)
            }
            continue
        }
        if escaping {
            hide(ch)
            escaping = false
        } else if ch == "\\" {
            escaping = true
        } else if ch == "`" {
            inCode = true
            code = ""
        } else {
            out.append(ch)
        }
    }
    if inCode {                            // unterminated span stays literal
        out.append(hideAll("`" + code, base))
    }
    if escaping { out.append("\\") }        // a trailing lone backslash
    return out
}

/// Map every escapable character in a string onto the private-use range.
private func hideAll(_ s: String, _ base: UInt32) -> String {
    var out = ""
    for ch in s {
        if let i = ESCAPABLE.firstIndex(of: ch),
           let scalar = Unicode.Scalar(base + UInt32(i)) {
            out.unicodeScalars.append(scalar)
        } else {
            out.append(ch)
        }
    }
    return out
}

private func restoreEscapes(_ s: String, _ base: UInt32) -> String {
    var out = ""
    for ch in s {
        let u = ch.unicodeScalars
        if u.count == 1, let v = u.first?.value,
           v >= base, v < base + UInt32(ESCAPABLE.count) {
            out.append(ESCAPABLE[Int(v - base)])
        } else {
            out.append(ch)
        }
    }
    return out
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
    case bullet
    case ordered
    case quote
}

/// Pull inline emphasis out of a line, leaving styled spans behind.
private func inlineSpans(_ line: String, forceBold: Bool) -> [Span] {
    let base = escapeBase(for: line)
    var s = protectInline(line, base)

    // "[text](url)" -> "text (url)", or just the url when the label adds nothing.
    while let m = LINK.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
        guard let whole = Range(m.range, in: s) else { break }
        let label = Range(m.range(at: 1), in: s).map { String(s[$0]) } ?? ""
        let url = Range(m.range(at: 2), in: s).map { String(s[$0]) } ?? ""
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        s.replaceSubrange(whole, with: trimmed.isEmpty || trimmed == url
                          ? url : "\(trimmed) (\(url))")
    }

    // Mark emphasis with sentinels so the spans survive unescaping.
    let B = "\u{1}", I = "\u{2}", S = "\u{3}"
    // Triple delimiters first: otherwise the strong pass eats two and the
    // emphasis pass eats the rest, losing bold from "***both***".
    s = sub(s, TRIPLE_STAR, "\(B)\(I)$1\(I)\(B)")
    s = sub(s, TRIPLE_UNDER, "\(B)\(I)$1\(I)\(B)")
    s = sub(s, STRONG_STAR, "\(B)$1\(B)")
    s = sub(s, STRONG_UNDER, "\(B)$1\(B)")
    s = sub(s, STRIKE, "\(S)$2\(S)")
    s = sub(s, EMPH, "\(I)$2\(I)")

    var spans: [Span] = []
    var cur = ""
    var bold = false, italic = false, strike = false
    func flush() {
        if !cur.isEmpty {
            spans.append(Span(text: restoreEscapes(cur, base), bold: bold || forceBold,
                              italic: italic, strike: strike))
            cur = ""
        }
    }
    for ch in s {
        switch ch {
        case "\u{1}": flush(); bold.toggle()
        case "\u{2}": flush(); italic.toggle()
        case "\u{3}": flush(); strike.toggle()
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
    var inFence = false

    // CRLF must not split twice: .newlines treats \r and \n as separate
    // delimiters, which would insert a blank line after every source line.
    let normalized = md.replacingOccurrences(of: "\r\n", with: "\n")
                       .replacingOccurrences(of: "\r", with: "\n")
    for raw in normalized.components(separatedBy: "\n") {
        if hits(raw, FENCE) { inFence.toggle(); continue }
        if inFence {
            kinds.append(.body)
            contents.append([Span(text: raw)])
            continue
        }
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

    while out.length > 0, out.string.hasSuffix("\n") {
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
