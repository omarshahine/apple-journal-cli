// Support.swift — paths, process helpers, errors, arg scanning.
import Foundation

let CORE_DATA_EPOCH = 978307200.0 // Core Data reference date -> unix epoch

var DB_PATH = ProcessInfo.processInfo.environment["JOURNAL_DB"]
    ?? (NSHomeDirectory() + "/Library/Group Containers/group.com.apple.moments/Library/moments.sqlite")

var DEFAULT_DB: String {
    NSHomeDirectory() + "/Library/Group Containers/group.com.apple.moments/Library/moments.sqlite"
}

var BACKUPS_DIR: String { NSHomeDirectory() + "/Backups/journal-cli" }

func attachDir() -> String {
    (URL(fileURLWithPath: DB_PATH).deletingLastPathComponent()
        .appendingPathComponent("Attachments")).path
}

func externalDataDir() -> String {
    (URL(fileURLWithPath: DB_PATH).deletingLastPathComponent()
        .appendingPathComponent(".moments_SUPPORT/_EXTERNAL_DATA")).path
}

func die(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write("journal-cli: \(msg)\n".data(using: .utf8)!)
    exit(code)
}

func cdNow() -> Double { Date().timeIntervalSince1970 - CORE_DATA_EPOCH }
func cd(_ d: Date) -> Double { d.timeIntervalSince1970 - CORE_DATA_EPOCH }

func uid() -> String { UUID().uuidString.uppercased() }

func uidBytes(_ u: String) -> Data {
    guard let x = UUID(uuidString: u) else { die("bad uuid \(u)") }
    var t = x.uuid
    return withUnsafeBytes(of: &t) { Data($0) }
}

func uString(_ d: Data?) -> String? {
    guard let d = d, d.count == 16 else { return nil }
    let b = [UInt8](d)
    let t: uuid_t = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                     b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
    return UUID(uuid: t).uuidString.uppercased()
}

func journalRunning() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "Journal"]
    p.standardOutput = Pipe(); p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}

func fmtDate(_ cdTimestamp: Double) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.timeZone = .current
    return f.string(from: Date(timeIntervalSince1970: cdTimestamp + CORE_DATA_EPOCH))
}

func parseDate(_ s: String) -> Date {
    for fmt in ["yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
        let f = DateFormatter()
        f.dateFormat = fmt
        f.timeZone = .current
        if let d = f.date(from: s) { return d }
    }
    die("cannot parse date '\(s)' (use YYYY-MM-DD)")
}

// ---------------------------------------------------------------- arg scanning

struct Args {
    var positional: [String] = []
    private var flags: [String: [String]] = [:]
    private var present: Set<String> = []

    init(_ raw: [String], listFlags: Set<String> = [], valueFlags: Set<String> = [],
         boolFlags: Set<String> = []) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if boolFlags.contains(a) {
                present.insert(a)
            } else if valueFlags.contains(a) {
                guard i + 1 < raw.count else { die("\(a) needs a value") }
                flags[a, default: []].append(raw[i + 1]); present.insert(a); i += 1
            } else if listFlags.contains(a) {
                present.insert(a)
                var vals: [String] = []
                while i + 1 < raw.count && !raw[i + 1].hasPrefix("--") {
                    vals.append(raw[i + 1]); i += 1
                }
                if vals.isEmpty { die("\(a) needs at least one value") }
                flags[a, default: []].append(contentsOf: vals)
            } else if a.hasPrefix("--") {
                die("unknown option \(a)")
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func has(_ f: String) -> Bool { present.contains(f) }
    func value(_ f: String) -> String? { flags[f]?.last }
    func values(_ f: String) -> [String] { flags[f] ?? [] }
    func int(_ f: String) -> Int? { value(f).flatMap { Int($0) } }
    func double(_ f: String) -> Double? { value(f).flatMap { Double($0) } }
}
