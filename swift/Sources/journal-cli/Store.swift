// Store.swift — snapshot reads, guarded live writes, backups, RTF, metadata.
import Foundation
import AppKit
import SQLite3

// ---------------------------------------------------------------- snapshot / live

/// Copy a SQLite store into one consistent file with SQLite's online backup
/// API. Copying the database, -wal and -shm one after another could mix
/// generations if Journal checkpointed in between; the backup API reads every
/// page inside a single read transaction instead. The source is opened
/// read-only; a WAL reader never blocks Journal's own writes.
/// Returns nil on success, else a description of the failure.
func sqliteBackup(from src: String, to dst: String) -> String? {
    var s: OpaquePointer?, d: OpaquePointer?
    defer { sqlite3_close(s); sqlite3_close(d) }
    guard sqlite3_open_v2(src, &s, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        return "cannot open \(src): " + (s.map { String(cString: sqlite3_errmsg($0)) } ?? "?")
    }
    sqlite3_busy_timeout(s, 5000)
    guard sqlite3_open_v2(dst, &d, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        return "cannot create \(dst): " + (d.map { String(cString: sqlite3_errmsg($0)) } ?? "?")
    }
    guard let b = sqlite3_backup_init(d, "main", s, "main") else {
        return String(cString: sqlite3_errmsg(d))
    }
    var rc: Int32 = SQLITE_OK
    var busy = 0
    while true {
        rc = sqlite3_backup_step(b, -1)
        if (rc == SQLITE_BUSY || rc == SQLITE_LOCKED) && busy < 50 {
            busy += 1; sqlite3_sleep(100); continue
        }
        if rc != SQLITE_OK { break }
    }
    sqlite3_backup_finish(b)
    return rc == SQLITE_DONE ? nil : String(cString: sqlite3_errstr(rc))
}

/// Read-only access: a consistent copy of the store, so the live one is never written.
func withSnapshot<T>(_ body: (DB) -> T) -> T {
    let fm = FileManager.default
    guard fm.fileExists(atPath: DB_PATH) else { die("store not found at \(DB_PATH)") }
    let tmp = NSTemporaryDirectory() + "journal-cli." + uid()
    do { try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true) }
    catch { die("cannot create a temp folder for the snapshot: \(error.localizedDescription)") }
    defer { try? fm.removeItem(atPath: tmp) }
    let copy = tmp + "/" + URL(fileURLWithPath: DB_PATH).lastPathComponent
    if let err = sqliteBackup(from: DB_PATH, to: copy) {
        if !fm.isReadableFile(atPath: DB_PATH) {
            die("permission denied. Grant Full Disk Access to this terminal, then relaunch it.")
        }
        die("could not snapshot the store: \(err)")
    }
    return body(DB(path: copy))
}

/// Back up the store before a live write. Fails closed: if anything goes
/// wrong the write is refused, never run without its backup. Every call gets
/// its own folder, so two writes in the same second keep two recovery points.
func takeBackup(reason: String = "write") -> String {
    let fm = FileManager.default
    let root = BACKUPS_DIR
    do { try fm.createDirectory(atPath: root, withIntermediateDirectories: true) }
    catch { die("backup failed: cannot create \(root): \(error.localizedDescription)\n  Nothing was written.") }
    let f = fixedFormatter("yyyyMMdd-HHmmss")
    let stem = root + "/" + f.string(from: Date()) + "-" + reason
    var dir = stem
    var n = 1
    while mkdir(dir, 0o755) != 0 {
        guard errno == EEXIST, n < 1000 else {
            die("backup failed: cannot create \(dir): \(String(cString: strerror(errno)))\n  Nothing was written.")
        }
        n += 1; dir = stem + "-\(n)"
    }
    let dst = dir + "/" + URL(fileURLWithPath: DB_PATH).lastPathComponent
    if let err = sqliteBackup(from: DB_PATH, to: dst) {
        die("backup failed: \(err)\n  Nothing was written.")
    }
    return dir
}

/// Filesystem side effects of the open live write. Removals wait until the
/// database transaction commits, so a write that dies part way never leaves
/// rows pointing at deleted files; and they move into the write's backup when
/// it has one, so restoring that backup brings the removed media back.
final class LiveFiles {
    var created: [String] = []
    var removals: [String] = []
}
var LIVE_FILES: LiveFiles?

/// An attachment folder this write made; removed again if the write aborts.
func stageCreated(_ path: String) { LIVE_FILES?.created.append(path) }

/// Remove an attachment folder once the write commits.
func scheduleRemoval(_ path: String) {
    if let l = LIVE_FILES { l.removals.append(path) }
    else { try? FileManager.default.removeItem(atPath: path) }
}

private func applyRemovals(_ files: LiveFiles, backup: String?) {
    let fm = FileManager.default
    let root = attachDir()
    for path in files.removals where fm.fileExists(atPath: path) {
        guard let backup = backup else { try? fm.removeItem(atPath: path); continue }
        let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1))
                                            : URL(fileURLWithPath: path).lastPathComponent
        let dest = backup + "/Attachments/" + rel
        do {
            try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try fm.moveItem(atPath: path, toPath: dest)
        } catch {
            // The database change is committed; leaving the files in place
            // loses nothing, it only leaves them unreferenced.
            FileHandle.standardError.write(
                "journal-cli: warning: kept \(path) (could not move it into the backup: \(error.localizedDescription))\n"
                    .data(using: .utf8)!)
        }
    }
}

let RISK_MARKER = NSHomeDirectory() + "/.config/journal-cli/risk-accepted"

let RISK_WARNING = """
================================ WARNING =====================================
journal-cli writes DIRECTLY to Apple Journal's private, undocumented data
store. Apple does not support this. A future macOS update can change the
schema at any time, and a malformed write could corrupt entries or confuse
iCloud sync across ALL your devices.

Before your first live write:
  1. BACK UP your journal in Journal.app:
       Journal -> Settings -> Export Journal Entries...
  2. Know that journal-cli also snapshots the local store to
     ~/Backups/journal-cli/ before every live write -- but that cannot undo
     anything that has already synced to iCloud.

You use this tool AT YOUR OWN RISK.
==============================================================================
"""

func ensureRiskAccepted(acceptFlag: Bool) {
    if FileManager.default.fileExists(atPath: RISK_MARKER) { return }
    func record() {
        try? FileManager.default.createDirectory(
            atPath: (RISK_MARKER as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? "accepted \(Date())\n".write(toFile: RISK_MARKER, atomically: true, encoding: .utf8)
    }
    FileHandle.standardError.write((RISK_WARNING + "\n").data(using: .utf8)!)
    if acceptFlag {
        FileHandle.standardError.write("Risk accepted via --accept-risk.\n".data(using: .utf8)!)
        record(); return
    }
    if isatty(0) != 0 {
        FileHandle.standardError.write("Type \"I understand\" to continue: ".data(using: .utf8)!)
        let line = readLine() ?? ""
        if line.trimmingCharacters(in: .whitespaces).lowercased() == "i understand" {
            record(); return
        }
        die("not accepted; nothing was written")
    }
    die("first live write requires accepting the risk above.\n"
        + "  Re-run with --accept-risk (agents: ask the user before passing this).")
}

/// Read-write against the target store, with the real-store guards.
func withLive<T>(allowLiveDefault: Bool, acceptRisk: Bool = false, _ body: (DB) -> T) -> T {
    let isDefault = (URL(fileURLWithPath: DB_PATH).resolvingSymlinksInPath().path
                     == URL(fileURLWithPath: DEFAULT_DB).resolvingSymlinksInPath().path)
    if isDefault {
        if !allowLiveDefault {
            die("refusing to modify the real Journal store without --live.\n"
                + "  Test against a sandbox first:  journal-cli sandbox --dir DIR")
        }
        ensureRiskAccepted(acceptFlag: acceptRisk)
        if journalRunning() { die("Journal.app is running. Quit it first, then retry.") }
    }
    var backup: String?
    if isDefault || BACKUP_OVERRIDE != nil {
        backup = takeBackup()
        FileHandle.standardError.write("backup: \(backup!)\n".data(using: .utf8)!)
    }
    let files = LiveFiles()
    LIVE_FILES = files
    DIE_CLEANUP = {
        for p in files.created.reversed() { try? FileManager.default.removeItem(atPath: p) }
    }
    let db = DB(path: DB_PATH)
    db.exec("BEGIN")
    let out = body(db)
    db.exec("COMMIT")
    DIE_CLEANUP = nil
    LIVE_FILES = nil
    applyRemovals(files, backup: backup)
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
