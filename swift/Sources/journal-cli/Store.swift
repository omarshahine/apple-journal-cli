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
    // Owner-only before any journal data lands in it.
    do {
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
    } catch { die("cannot create a temp folder for the snapshot: \(error.localizedDescription)") }
    // `die` exits without unwinding, so a plain defer would leave a full copy
    // of the journal behind on any refusal. Chain onto the fatal-exit cleanup
    // (keeping whatever was registered before) as well.
    let previous = DIE_CLEANUP
    DIE_CLEANUP = { try? FileManager.default.removeItem(atPath: tmp); previous?() }
    defer { DIE_CLEANUP = previous; try? fm.removeItem(atPath: tmp) }
    let copy = tmp + "/" + URL(fileURLWithPath: DB_PATH).lastPathComponent
    if let err = sqliteBackup(from: DB_PATH, to: copy) {
        if !fm.isReadableFile(atPath: DB_PATH) {
            die("permission denied. Grant Full Disk Access to this terminal, then relaunch it.")
        }
        die("could not snapshot the store: \(err)")
    }
    chmod(copy, 0o600)
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
    // Owner-only: a recovery point is a full copy of the journal (and gains
    // removed media later), so nobody else on the Mac may read it.
    while mkdir(dir, 0o700) != 0 {
        guard errno == EEXIST, n < 1000 else {
            die("backup failed: cannot create \(dir): \(String(cString: strerror(errno)))\n  Nothing was written.")
        }
        n += 1; dir = stem + "-\(n)"
    }
    let dst = dir + "/" + URL(fileURLWithPath: DB_PATH).lastPathComponent
    if let err = sqliteBackup(from: DB_PATH, to: dst) {
        try? fm.removeItem(atPath: dir)          // no half-written recovery point
        die("backup failed: \(err)\n  Nothing was written.")
    }
    for suf in ["", "-wal", "-shm"] where fm.fileExists(atPath: dst + suf) {
        chmod(dst + suf, 0o600)
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

/// Whether two paths are the same database file. Paths alone are not enough:
/// a hard link to the real store has its own path, and treating it as a
/// sandbox would skip --live, the risk check, the app check and the backup.
func sameStore(_ a: String, _ b: String) -> Bool {
    func canon(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
    if canon(a) == canon(b) { return true }
    var sa = stat(), sb = stat()
    guard stat(a, &sa) == 0, stat(b, &sb) == 0 else { return false }
    return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
}

/// Read-write against the target store, with the real-store guards.
/// One journal-cli writer per store at a time, for the whole write: backup,
/// transaction, and the file moves after commit. SQLite's write lock covers
/// only the middle part. Keyed by the store file's identity, so every path to
/// it (symlink, hard link) shares one lock. Released when the process exits.
private func lockStore(_ path: String) {
    var st = stat()
    guard stat(path, &st) == 0 else { return }
    // One fixed, owner-only place (not the temp folder, which TMPDIR can move),
    // under the account's real home -- the same one the Python reference uses.
    let dir = NSHomeDirectory() + "/Library/Caches/journal-cli/locks"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let lock = dir + "/write-\(st.st_dev)-\(st.st_ino).lock"
    let fd = open(lock, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { die("cannot open write lock \(lock): \(String(cString: strerror(errno)))") }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        FileHandle.standardError.write("journal-cli: waiting for another journal-cli write to finish...\n"
            .data(using: .utf8)!)
        guard flock(fd, LOCK_EX) == 0 else { die("cannot take write lock \(lock)") }
    }
    // fd stays open (and locked) until the process exits.
}

func withLive<T>(allowLiveDefault: Bool, acceptRisk: Bool = false, _ body: (DB) -> T) -> T {
    let isDefault = sameStore(DB_PATH, DEFAULT_DB)
    if isDefault && DB_PATH != DEFAULT_DB {
        // A symlink or hard link to the real store is the real store: use its
        // real path, so attachments, backups and removals land beside it rather
        // than beside the alias.
        DB_PATH = DEFAULT_DB
    }
    lockStore(DB_PATH)
    if isDefault {
        if !allowLiveDefault {
            die("refusing to modify the real Journal store without --live.\n"
                + "  Test against a sandbox first:  journal-cli sandbox --dir DIR")
        }
        ensureRiskAccepted(acceptFlag: acceptRisk)
        if journalRunning() { die("Journal.app is running. Quit it first, then retry.") }
    }
    // Take the write lock first and back up under it: no other writer can
    // commit between the backup and this write, so the recovery point is
    // exactly the state this write changes. (Readers, including the backup's
    // own connection, are not blocked by a reserved lock.)
    let db = DB(path: DB_PATH)
    sqlite3_busy_timeout(db.handle, 5000)
    db.exec("BEGIN IMMEDIATE")
    var backup: String?
    if isDefault || BACKUP_OVERRIDE != nil {
        backup = takeBackup()
        FileHandle.standardError.write("backup: \(backup!)\n".data(using: .utf8)!)
    }
    let files = LiveFiles()
    LIVE_FILES = files
    let previous = DIE_CLEANUP
    DIE_CLEANUP = {
        for p in files.created.reversed() { try? FileManager.default.removeItem(atPath: p) }
        previous?()
    }
    let out = body(db)
    db.exec("COMMIT")
    DIE_CLEANUP = previous
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
