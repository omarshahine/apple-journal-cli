// ReadCommands.swift — list, show, search, export, stats, journals, deleted, doctor.
import Foundation

func render(_ entries: [Entry], json: Bool, limit: Int?, full: Bool) {
    var ents = entries
    if let l = limit { ents = Array(ents.prefix(l)) }
    if json { printJSON(ents.map { $0.json }); return }
    if ents.isEmpty { print("No entries."); return }
    for e in ents {
        let mark = e.bookmarked ? "*" : (e.synced ? " " : "+")
        let head = !e.title.isEmpty ? e.title
            : (e.text.isEmpty ? "(empty)" : String(e.text.split(separator: "\n")[0].prefix(60)))
        print("\(mark)\(String(format: "%5d", e.id))  \(e.date ?? "")  \(head)")
        if full && !e.text.isEmpty {
            for line in e.text.split(separator: "\n", omittingEmptySubsequences: false) {
                print("        \(line)")
            }
            print("")
        }
    }
    print("\n\(ents.count) entr\(ents.count == 1 ? "y" : "ies").")
}

func cmdList(_ a: Args) {
    withSnapshot { db in
        render(fetch(db,
                     since: a.value("--since").map(parseDate),
                     until: a.value("--until").map(parseDate),
                     includeEmpty: a.has("--include-empty")),
               json: a.has("--json"), limit: a.int("--limit"), full: a.has("--full"))
    }
}

func cmdShow(_ a: Args) {
    guard let idStr = a.positional.first, let pk = Int64(idStr) else { die("show needs an entry id") }
    let (e, assets): (Entry?, [[String: Any]]) = withSnapshot { db in
        (fetchOne(db, pk), assetsFor(db, pk))
    }
    guard let e = e else { die("no entry with id \(pk)") }
    if a.has("--json") {
        var j = e.json; j["assets"] = assets
        printJSON(j); return
    }
    print("id      \(e.id)")
    print("uuid    \(e.uuid ?? "?")")
    print("date    \(e.date ?? "?")")
    if !e.title.isEmpty { print("title   \(e.title)") }
    var flags: [String] = []
    if e.bookmarked { flags.append("bookmarked") }
    if e.draft { flags.append("draft") }
    if !e.synced { flags.append("unsynced") }
    if !flags.isEmpty { print("flags   \(flags.joined(separator: ", "))") }
    print("")
    print(e.text.isEmpty ? "(no text)" : e.text)
    for asset in assets {
        let aid = asset["id"] as? Int64 ?? 0
        if asset["transcript"] != nil || asset["duration"] != nil {
            let dur = (asset["duration"] as? Double).map { String(format: "%.1fs", $0) } ?? ""
            let tr = (asset["transcript"] as? String).map { "  \"\($0)\"" } ?? ""
            print("\naudio (asset \(aid))  \(dur)\(tr)")
        }
        if let dtext = asset["drawing_text"] as? String {
            print("\ndrawing (asset \(aid))  text: \(dtext)")
        }
        if let url = asset["url"] as? String {
            let t = (asset["link_title"] as? String).map { "  \($0)" } ?? ""
            print("\nlink (asset \(aid))  \(url)\(t)")
        }
        for p in (asset["places"] as? [[String: Any]]) ?? [] {
            let bits = [p["name"] as? String, p["city"] as? String].compactMap { $0 }
            let loc = bits.isEmpty ? "(unnamed)" : bits.joined(separator: ", ")
            let lat = (p["lat"] as? Double).map { String($0) } ?? "?"
            let lon = (p["lon"] as? Double).map { String($0) } ?? "?"
            print("\nlocation  \(loc)  (\(lat), \(lon))")
        }
        for f in (asset["files"] as? [[String: Any]]) ?? [] {
            let ok = (f["exists"] as? Bool ?? false) ? "ok" : "MISSING"
            print("\n\(asset["type"] ?? "?") (asset \(aid))  \(ok)  \(f["path"] ?? "?")")
        }
    }
}

func cmdSearch(_ a: Args) {
    guard let q = a.positional.first?.lowercased() else { die("search needs a query") }
    let hits: [Entry] = withSnapshot { db in
        fetch(db).filter { $0.text.lowercased().contains(q) || $0.title.lowercased().contains(q) }
    }
    render(hits, json: a.has("--json"), limit: a.int("--limit"), full: a.has("--full"))
}

func cmdExport(_ a: Args) {
    guard let dir = a.value("--dir") else { die("export needs --dir") }
    let format = a.value("--format") ?? "md"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let payload: [(Entry, [[String: Any]])] = withSnapshot { db in
        fetch(db).map { ($0, assetsFor(db, $0.id)) }
    }
    if format == "json" {
        let arr = payload.map { (e, assets) -> [String: Any] in
            var j = e.json; j["assets"] = assets; return j
        }
        let p = dir + "/journal.json"
        try! JSONSerialization.data(withJSONObject: arr,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: URL(fileURLWithPath: p))
        print("Wrote \(payload.count) entries to \(p)")
        return
    }
    for (e, assets) in payload {
        var slug = e.title.filter { $0.isLetter || $0.isNumber || "-_ ".contains($0) }
        slug = String(slug.prefix(50)).trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        let stamp = String((e.date ?? "").prefix(10))
        let name = "\(stamp)-\(e.id)\(slug.isEmpty ? "" : "-" + slug).md"
        var out = "---\ndate: \(e.date ?? "")\nid: \(e.id)\n"
        if !e.title.isEmpty {
            let t = try! JSONSerialization.data(withJSONObject: [e.title])
            let ts = String(data: t, encoding: .utf8)!.dropFirst().dropLast()
            out += "title: \(ts)\n"
        }
        if e.bookmarked { out += "bookmarked: true\n" }
        let places = assets.flatMap { ($0["places"] as? [[String: Any]]) ?? [] }
        if !places.isEmpty {
            out += "locations:\n"
            for p in places {
                let nm = (p["name"] as? String).map { "\"\($0)\"" } ?? "null"
                out += "  - name: \(nm)\n    lat: \(p["lat"] ?? "null")\n    lon: \(p["lon"] ?? "null")\n"
            }
        }
        out += "---\n\n" + e.text + "\n"
        let files = assets.flatMap { ($0["files"] as? [[String: Any]]) ?? [] }
        if !files.isEmpty {
            out += "\n"
            for f in files {
                out += "![\(f["name"] as? String ?? "file")](\(f["path"] as? String ?? ""))\n"
            }
        }
        try? out.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
    }
    print("Wrote \(payload.count) entries to \(dir)")
}

func cmdStats(_ a: Args) {
    let (ents, nAttach, nLoc): ([Entry], Int64, Int64) = withSnapshot { db in
        (fetch(db, includeEmpty: true),
         db.scalarInt("select count(*) from ZJOURNALENTRYASSETFILEATTACHMENTMO") ?? 0,
         db.scalarInt("""
            select count(*) from ZJOURNALENTRYASSETMO
            where ZASSETTYPE in ('multiPinMap','genericMap')
            """) ?? 0)
    }
    let real = ents.filter { !$0.text.isEmpty }
    let words = real.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    var byYear: [String: Int] = [:]
    for e in real { byYear[String((e.date ?? "????").prefix(4)), default: 0] += 1 }
    let fmt = NumberFormatter(); fmt.numberStyle = .decimal
    print("entries      \(real.count) with text (\(ents.count) rows total)")
    print("words        \(fmt.string(from: NSNumber(value: words)) ?? String(words))")
    print("attachments  \(nAttach)")
    print("locations    \(nLoc)")
    if let last = real.last?.date, let first = real.first?.date {
        print("range        \(last.prefix(10)) .. \(first.prefix(10))")
    }
    print("\nby year")
    for y in byYear.keys.sorted() {
        let n = byYear[y]!
        print("  \(y)  \(String(format: "%4d", n))  \(String(repeating: "#", count: min(n, 50)))")
    }
}

func cmdJournals(_ a: Args) {
    let (rows, counts, unassigned): ([JournalRow], [Int64: Int64], Int64) = withSnapshot { db in
        let live = "coalesce(e.ZISFULLYREMOVED,0)=0 and coalesce(e.ZRECENTLYDELETED,0)=0 "
            + "and coalesce(e.ZISTIP,0)=0 and e.ZENTRYDATE is not null"
        var c: [Int64: Int64] = [:]
        for r in db.query("""
            select j.Z_6JOURNALS as jid, count(*) as n from Z_5JOURNALS j
            join ZJOURNALENTRYMO e on e.Z_PK=j.Z_5ENTRIES where \(live) group by 1
            """) { c[r.i("jid") ?? 0] = r.i("n") ?? 0 }
        let u = db.scalarInt("""
            select count(*) from ZJOURNALENTRYMO e where \(live)
            and not exists(select 1 from Z_5JOURNALS j where j.Z_5ENTRIES=e.Z_PK)
            """) ?? 0
        return (journalRows(db), c, u)
    }
    if a.has("--json") {
        printJSON(rows.map { j -> [String: Any] in
            ["pk": j.pk, "name": j.name, "default": j.isDefault,
             "entries": (counts[j.pk] ?? 0) + (j.isDefault ? unassigned : 0)]
        })
        return
    }
    for j in rows {
        let n = (counts[j.pk] ?? 0) + (j.isDefault ? unassigned : 0)
        let tag = j.isDefault ? "  (default)" : ""
        print("\(String(format: "%3d", j.pk))  \(j.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(String(format: "%4d", n)) entries\(tag)")
    }
}

func cmdDeleted(_ a: Args) {
    let rows: [[String: Any]] = withSnapshot { db in
        db.query("""
            select Z_PK, ZENTRYDATE, ZRECENTLYDELETEDENTRYDATE, ZISUPLOADEDTOCLOUD, ZTITLE, ZTEXT
            from ZJOURNALENTRYMO
            where coalesce(ZRECENTLYDELETED,0)=1 and coalesce(ZISFULLYREMOVED,0)=0
            order by ZRECENTLYDELETEDENTRYDATE desc
            """)
    }
    let out = rows.map { r -> [String: Any] in
        ["id": r.i("Z_PK") ?? 0,
         "date": r.d("ZENTRYDATE").map(fmtDate) as Any,
         "deleted": r.d("ZRECENTLYDELETEDENTRYDATE").map(fmtDate) as Any,
         "title": rtfToText(r.b("ZTITLE")),
         "text": rtfToText(r.b("ZTEXT")),
         "synced": r.flag("ZISUPLOADEDTOCLOUD")]
    }
    if a.has("--json") { printJSON(out); return }
    if out.isEmpty { print("Recently Deleted is empty."); return }
    for e in out {
        let title = e["title"] as? String ?? ""
        let text = e["text"] as? String ?? ""
        let head = !title.isEmpty ? title
            : (text.isEmpty ? "(empty)" : String(text.split(separator: "\n")[0].prefix(50)))
        let d = String(((e["date"] as? String) ?? "?").prefix(10))
        let dd = String(((e["deleted"] as? String) ?? "?").prefix(16))
        print("\(String(format: "%5d", e["id"] as? Int64 ?? 0))  entry \(d)  deleted \(dd)  \(head)")
    }
    print("\n\(out.count) entr\(out.count == 1 ? "y" : "ies") in Recently Deleted."
          + "  restore <id> brings one back; they purge ~30 days after deletion.")
}

func cmdDoctor(_ a: Args) {
    var ok = true
    print("store    \(DB_PATH)")
    guard FileManager.default.fileExists(atPath: DB_PATH) else {
        print("         NOT FOUND"); exit(1)
    }
    if let fh = FileHandle(forReadingAtPath: DB_PATH) {
        _ = try? fh.read(upToCount: 16); try? fh.close()
        let sz = (try? FileManager.default.attributesOfItem(atPath: DB_PATH)[.size] as? Int64) ?? 0
        print("         readable, \(String(format: "%.1f", Double(sz) / 1e6)) MB")
    } else {
        print("         PERMISSION DENIED - grant Full Disk Access"); ok = false
    }
    var isDir: ObjCBool = false
    let att = FileManager.default.fileExists(atPath: attachDir(), isDirectory: &isDir) && isDir.boolValue
    print("attach   \(attachDir())  \(att ? "ok" : "missing")")
    print("Journal  \(journalRunning() ? "RUNNING (quit before writing)" : "not running")")
    if ok {
        let n = withSnapshot { fetch($0).count }
        print("\nRead \(n) entries. All good.")
    }
    exit(ok ? 0 : 1)
}
