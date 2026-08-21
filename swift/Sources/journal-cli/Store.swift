// Store.swift — snapshot reads, guarded live writes, backups, RTF, metadata.
import Foundation
import AppKit

// ---------------------------------------------------------------- snapshot / live

/// Read-only access: copy db + -wal + -shm aside so the live store is never touched.
func withSnapshot<T>(_ body: (DB) -> T) -> T {
    let fm = FileManager.default
    guard fm.fileExists(atPath: DB_PATH) else { die("store not found at \(DB_PATH)") }
    let tmp = NSTemporaryDirectory() + "journal-cli." + uid()
    try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: tmp) }
    let base = URL(fileURLWithPath: DB_PATH).lastPathComponent
    for suf in ["", "-wal", "-shm"] {
        let src = DB_PATH + suf
        if fm.fileExists(atPath: src) {
            do { try fm.copyItem(atPath: src, toPath: tmp + "/" + base + suf) }
            catch {
                die("permission denied. Grant Full Disk Access to this terminal, then relaunch it.")
            }
        }
    }
    return body(DB(path: tmp + "/" + base))
}

func takeBackup(reason: String = "write") -> String {
    let fm = FileManager.default
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
    let dir = BACKUPS_DIR + "/" + f.string(from: Date()) + "-" + reason
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let base = URL(fileURLWithPath: DB_PATH).lastPathComponent
    for suf in ["", "-wal", "-shm"] where fm.fileExists(atPath: DB_PATH + suf) {
        try? fm.copyItem(atPath: DB_PATH + suf, toPath: dir + "/" + base + suf)
    }
    return dir
}

/// Read-write against the target store, with the real-store guards.
func withLive<T>(allowLiveDefault: Bool, _ body: (DB) -> T) -> T {
    let isDefault = (URL(fileURLWithPath: DB_PATH).resolvingSymlinksInPath().path
                     == URL(fileURLWithPath: DEFAULT_DB).resolvingSymlinksInPath().path)
    if isDefault {
        if !allowLiveDefault {
            die("refusing to modify the real Journal store without --live.\n"
                + "  Test against a sandbox first:  journal-cli sandbox --dir DIR")
        }
        if journalRunning() { die("Journal.app is running. Quit it first, then retry.") }
        FileHandle.standardError.write("backup: \(takeBackup())\n".data(using: .utf8)!)
    }
    let db = DB(path: DB_PATH)
    db.exec("BEGIN")
    let out = body(db)
    db.exec("COMMIT")
    return out
}

// ---------------------------------------------------------------- RTF

func rtfToText(_ blob: Data?) -> String {
    guard let blob = blob, !blob.isEmpty else { return "" }
    guard let att = NSAttributedString(rtf: blob, documentAttributes: nil) else { return "" }
    return att.string.trimmingCharacters(in: .whitespacesAndNewlines)
}

func textToRTF(_ text: String) -> Data {
    let att = NSAttributedString(string: text,
        attributes: [.font: NSFont.systemFont(ofSize: 12)])
    guard let d = att.rtf(from: NSRange(location: 0, length: att.length),
                          documentAttributes: [:]) else {
        die("could not build RTF")
    }
    return d
}

// ---------------------------------------------------------------- asset metadata

/// Journal asset metadata: version byte 0x01 + JSON; 0x02 + UUID = Core Data
/// external-storage ref into .moments_SUPPORT/_EXTERNAL_DATA/.
func metaBlob(_ obj: [String: Any]) -> Data {
    var d = Data([0x01])
    d.append(try! JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]))
    return d
}

func parseMeta(_ b: Data?) -> [String: Any]? {
    guard let b = b, !b.isEmpty else { return nil }
    if b.first == 0x02 {
        var t = b.dropFirst()
        while t.last == 0 { t = t.dropLast() }
        guard let ref = String(data: t, encoding: .ascii) else { return nil }
        return ["ref": ref]
    }
    let body = b.first == 0x01 ? b.dropFirst() : b[...]
    return (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
}

func resolveMeta(_ b: Data?) -> [String: Any]? {
    guard let p = parseMeta(b) else { return nil }
    if p.count == 1, let ref = p["ref"] as? String {
        let f = externalDataDir() + "/" + ref
        if let raw = FileManager.default.contents(atPath: f),
           var ext = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
            ext["_external"] = ref
            return ext
        }
    }
    return p
}

// ---------------------------------------------------------------- JSON output

func printJSON(_ obj: Any) {
    let d = try! JSONSerialization.data(withJSONObject: obj,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(data: d, encoding: .utf8)!)
}
