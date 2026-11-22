// Compiled together with DB.swift and Support.swift by CI (see ci.yml) to
// check what no CLI input can reach: argv cannot carry U+0000 and file
// bodies are stored as RTF blobs, so DB.bind's text path is exercised here.
import Foundation

let path = NSTemporaryDirectory() + "journal-cli-db-check-\(getpid()).sqlite"
defer { try? FileManager.default.removeItem(atPath: path) }
let db = DB(path: path)
db.exec("create table t(v text)")
let s = "before\u{0}after"
db.exec("insert into t values (?)", [s])
let bound = db.scalarInt("select length(cast(v as blob)) from t") ?? -1
let back = db.one("select v from t")?["v"] as? String
guard bound == Int64(s.utf8.count), back == s else {
    FileHandle.standardError.write("FAIL: NUL text bound \(bound) of \(s.utf8.count) bytes; read back \(String(describing: back))\n".data(using: .utf8)!)
    exit(1)
}
print("PASS  text with an embedded NUL binds and reads back whole")
