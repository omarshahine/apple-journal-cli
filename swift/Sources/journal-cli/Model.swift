// Model.swift — entries, assets, journals: queries shared by the commands.
import Foundation

struct Entry {
    var id: Int64
    var uuid: String?
    var date: String?
    var title: String
    var text: String
    var chars: Int64
    var bookmarked: Bool
    var draft: Bool
    var synced: Bool

    var json: [String: Any] {
        ["id": id, "uuid": uuid as Any, "date": date as Any, "title": title, "text": text,
         "chars": chars, "bookmarked": bookmarked, "draft": draft, "synced": synced]
    }
}

private func entryFrom(_ r: [String: Any]) -> Entry? {
    guard let dt = r.d("ZENTRYDATE") else { return nil }
    return Entry(id: r.i("Z_PK") ?? 0, uuid: uString(r.b("ZID")), date: fmtDate(dt),
                 title: rtfToText(r.b("ZTITLE")), text: rtfToText(r.b("ZTEXT")),
                 chars: r.i("ZTEXTLENGTH") ?? 0, bookmarked: r.flag("ZFLAGGED"),
                 draft: r.flag("ZISDRAFT"), synced: r.flag("ZISUPLOADEDTOCLOUD"))
}

func fetch(_ db: DB, since: Date? = nil, until: Date? = nil, includeEmpty: Bool = false) -> [Entry] {
    let rows = db.query("""
        select Z_PK, ZID, ZENTRYDATE, ZTEXTLENGTH, ZFLAGGED, ZISDRAFT,
               ZISUPLOADEDTOCLOUD, ZTITLE, ZTEXT
        from ZJOURNALENTRYMO
        where coalesce(ZISFULLYREMOVED,0)=0 and coalesce(ZRECENTLYDELETED,0)=0
        order by ZENTRYDATE desc
        """)
    var out: [Entry] = []
    for r in rows {
        guard let e = entryFrom(r), let ts = r.d("ZENTRYDATE") else { continue }
        let d = Date(timeIntervalSince1970: ts + CORE_DATA_EPOCH)
        if let s = since, d < s { continue }
        if let u = until, d > u { continue }
        if !includeEmpty && e.text.isEmpty && e.title.isEmpty { continue }
        out.append(e)
    }
    return out
}

func fetchOne(_ db: DB, _ pk: Int64) -> Entry? {
    guard let r = db.one("""
        select Z_PK, ZID, ZENTRYDATE, ZTEXTLENGTH, ZFLAGGED, ZISDRAFT,
               ZISUPLOADEDTOCLOUD, ZTITLE, ZTEXT
        from ZJOURNALENTRYMO where Z_PK=?
        """, [pk]) else { return nil }
    if r.d("ZENTRYDATE") == nil {
        // still return it, with a nil date
        return Entry(id: r.i("Z_PK") ?? 0, uuid: uString(r.b("ZID")), date: nil,
                     title: rtfToText(r.b("ZTITLE")), text: rtfToText(r.b("ZTEXT")),
                     chars: r.i("ZTEXTLENGTH") ?? 0, bookmarked: r.flag("ZFLAGGED"),
                     draft: r.flag("ZISDRAFT"), synced: r.flag("ZISUPLOADEDTOCLOUD"))
    }
    return entryFrom(r)
}

// ---------------------------------------------------------------- assets

func assetsFor(_ db: DB, _ pk: Int64) -> [[String: Any]] {
    var out: [[String: Any]] = []
    for r in db.query("""
        select Z_PK, ZID, ZASSETTYPE, ZSOURCE, ZASSETMETADATA
        from ZJOURNALENTRYASSETMO where ZENTRY=? order by Z_PK
        """, [pk]) {
        let m = resolveMeta(r.b("ZASSETMETADATA")) ?? [:]
        let type = r.s("ZASSETTYPE") ?? "?"
        var a: [String: Any] = ["id": r.i("Z_PK") ?? 0, "uuid": uString(r.b("ZID")) as Any,
                                "type": type, "source": r.s("ZSOURCE") as Any]
        switch type {
        case "multiPinMap", "genericMap":
            var places: [[String: Any]] = []
            for v in (m["visitsData"] as? [[String: Any]]) ?? [] where v["latitude"] != nil {
                places.append(["name": v["placeName"] as Any, "city": v["city"] as Any,
                               "lat": v["latitude"] as Any, "lon": v["longitude"] as Any])
            }
            a["places"] = places
        case "audio":
            if let d = m["duration"] { a["duration"] = d }
            let segs = (m["transcriptSegments"] as? [[String: Any]]) ?? []
            let words = segs.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
            if !words.isEmpty { a["transcript"] = words.joined(separator: " ") }
        case "drawing":
            if let ic = (m["indexableContent"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !ic.isEmpty {
                a["drawing_text"] = ic
            }
        case "link":
            let (url, title) = decodeLinkPayload(m)
            if let url = url { a["url"] = url }
            if let title = title { a["link_title"] = title }
        default:
            if m["latitude"] != nil {
                a["place"] = ["name": m["placeName"] as Any,
                              "lat": m["latitude"] as Any, "lon": m["longitude"] as Any]
            }
        }
        // photo/video may also carry a place
        if a["place"] == nil, ["photo", "video", "livePhoto"].contains(type), m["latitude"] != nil {
            a["place"] = ["name": m["placeName"] as Any,
                          "lat": m["latitude"] as Any, "lon": m["longitude"] as Any]
        }
        var files: [[String: Any]] = []
        for f in db.query("""
            select ZFILEPATH, ZNAME, ZINDEX from ZJOURNALENTRYASSETFILEATTACHMENTMO
            where ZASSET=? order by ZINDEX
            """, [r.i("Z_PK") ?? 0]) {
            guard let p = f.s("ZFILEPATH"), !p.isEmpty else { continue }
            let full = p.hasPrefix("/") ? p : attachDir() + "/" + p
            files.append(["path": full, "name": f.s("ZNAME") as Any,
                          "exists": FileManager.default.fileExists(atPath: full)])
        }
        a["files"] = files
        out.append(a)
    }
    return out
}

// ---------------------------------------------------------------- journals

struct JournalRow { var pk: Int64; var name: String; var isDefault: Bool }

func journalRows(_ db: DB) -> [JournalRow] {
    var out: [JournalRow] = []
    for r in db.query("""
        select Z_PK, ZMERGEABLEATTRIBUTES, ZSORTCATEGORY from ZJOURNALMO
        where coalesce(ZUSERDELETED,0)=0 order by Z_PK
        """) {
        var name = "Journal" // the built-in default has no CRDT blob
        var isDefault = false
        if let blob = r.b("ZMERGEABLEATTRIBUTES") {
            // pull printable runs; the string right before "title" is the name
            var cand: [String] = []
            var cur: [UInt8] = []
            for byte in blob {
                if byte >= 0x20 && byte < 0x7f { cur.append(byte) }
                else {
                    if cur.count >= 3, let s = String(bytes: cur, encoding: .utf8) { cand.append(s) }
                    cur = []
                }
            }
            if cur.count >= 3, let s = String(bytes: cur, encoding: .utf8) { cand.append(s) }
            if let i = cand.firstIndex(of: "title"), i > 0 { name = cand[i - 1] }
        } else if let sc = r.d("ZSORTCATEGORY"), sc < 0 {
            isDefault = true
        }
        out.append(JournalRow(pk: r.i("Z_PK") ?? 0, name: name, isDefault: isDefault))
    }
    return out
}

func resolveJournal(_ db: DB, _ sel: String) -> JournalRow {
    let rows = journalRows(db)
    if let pk = Int64(sel) {
        if let j = rows.first(where: { $0.pk == pk }) { return j }
        die("no journal with id \(sel)")
    }
    let hits = rows.filter { $0.name.lowercased() == sel.lowercased() }
    if hits.count == 1 { return hits[0] }
    if hits.isEmpty {
        die("no journal named '\(sel)'. Have: "
            + rows.map { "\($0.name) (\($0.pk))" }.joined(separator: ", "))
    }
    die("journal name '\(sel)' is ambiguous; use the id: "
        + hits.map { String($0.pk) }.joined(separator: ", "))
}

// ---------------------------------------------------------------- write helpers

func nextPK(_ db: DB, _ entityName: String) -> (ent: Int64, pk: Int64) {
    guard let row = db.one("select Z_ENT, Z_MAX from Z_PRIMARYKEY where Z_NAME=?", [entityName])
    else { die("entity \(entityName) missing from Z_PRIMARYKEY") }
    let pk = (row.i("Z_MAX") ?? 0) + 1
    db.exec("update Z_PRIMARYKEY set Z_MAX=? where Z_NAME=?", [pk, entityName])
    return (row.i("Z_ENT") ?? 0, pk)
}

@discardableResult
func addAsset(_ db: DB, entryPK: Int64, entryUUID: String, type: String, source: String,
              metadata: [String: Any]?, slim: Int = 0) -> (pk: Int64, uuid: String) {
    let (ent, pk) = nextPK(db, "JournalEntryAssetMO")
    let au = uid()
    db.exec("""
        insert into ZJOURNALENTRYASSETMO
          (Z_PK, Z_ENT, Z_OPT, ZENTRY, ZID, ZPARENTID, ZASSETTYPE, ZSOURCE,
           ZCREATEDDATE, ZASSETMETADATA, ZISSLIM, ZISHIDDEN, ZISBEINGEDITED,
           ZISUNDOABLYDELETED, ZISUPLOADEDTOCLOUD, ZISREMOVEDFROMCLOUD,
           ZREFRESHASSETMETADATA, ZMINIMUMSUPPORTEDAPPVERSION)
        values (?,?,1,?,?,?,?,?,?,?,?,0,0,0,0,0,0,0)
        """, [pk, ent, entryPK, uidBytes(au), uidBytes(entryUUID), type, source,
              cdNow(), metadata.map(metaBlob), slim])
    return (pk, au)
}

@discardableResult
func addFile(_ db: DB, assetPK: Int64, assetUUID: String, entryUUID: String,
             srcPath: String, index: Int, resize: Bool = true, plainName: Bool = false) -> Int64 {
    let e = ext(srcPath)
    let name: String
    if VIDEO_EXT.contains(e) { name = "video" }
    else if PHOTO_EXT.contains(e) { name = "image" }
    else { die("unsupported media type '.\(e)' (\(srcPath))") }
    let relDir = entryUUID + "/" + assetUUID
    let absDir = attachDir() + "/" + relDir
    try? FileManager.default.createDirectory(atPath: absDir, withIntermediateDirectories: true)
    let fname = plainName ? "\(uid()).\(e)" : "\(uid())_resized.\(e)"
    let dst = absDir + "/" + fname
    if name == "image" && resize { resizeInto(srcPath, dst) }
    else { try? FileManager.default.copyItem(atPath: srcPath, toPath: dst) }
    let (entID, pk) = nextPK(db, "JournalEntryAssetFileAttachmentMO")
    db.exec("""
        insert into ZJOURNALENTRYASSETFILEATTACHMENTMO
          (Z_PK, Z_ENT, Z_OPT, ZASSET, ZID, ZPARENTID, ZFILEPATH, ZNAME, ZINDEX,
           ZISUPLOADEDTOCLOUD, ZISREMOVEDFROMCLOUD)
        values (?,?,1,?,?,?,?,?,?,0,0)
        """, [pk, entID, assetPK, uidBytes(uid()), uidBytes(assetUUID),
              relDir + "/" + fname, name, index])
    return pk
}

// ---------------------------------------------------------------- asset ordering

func orderingAppend(_ db: DB, _ pk: Int64, _ newUUIDs: [String]) {
    var cur: [Any] = []
    if let row = db.one("select ZASSETORDERING from ZJOURNALENTRYMO where Z_PK=?", [pk]),
       let b = row.b("ZASSETORDERING"),
       let j = (try? JSONSerialization.jsonObject(with: b)) as? [Any] { cur = j }
    var next = -1
    var i = 1
    while i < cur.count { if let n = cur[i] as? Int, n > next { next = n }; i += 2 }
    next += 1
    for u in newUUIDs { cur.append(u); cur.append(next); next += 1 }
    db.exec("update ZJOURNALENTRYMO set ZASSETORDERING=? where Z_PK=?",
            [try! JSONSerialization.data(withJSONObject: cur), pk])
}

func orderingDrop(_ db: DB, _ pk: Int64, _ goneUUIDs: Set<String>) {
    guard let row = db.one("select ZASSETORDERING from ZJOURNALENTRYMO where Z_PK=?", [pk]),
          let b = row.b("ZASSETORDERING"),
          let cur = (try? JSONSerialization.jsonObject(with: b)) as? [Any] else { return }
    var out: [Any] = []
    var i = 0
    while i + 1 < cur.count {
        if let u = cur[i] as? String, !goneUUIDs.contains(u) {
            out.append(cur[i]); out.append(cur[i + 1])
        }
        i += 2
    }
    db.exec("update ZJOURNALENTRYMO set ZASSETORDERING=? where Z_PK=?",
            [try! JSONSerialization.data(withJSONObject: out), pk])
}

let MEDIA_TYPES: Set<String> = ["photo", "video", "livePhoto"]

func removeAssets(_ db: DB, entryPK: Int64, entryUUID: String?, assetPKs: [Int64]) -> Int {
    var gone: Set<String> = []
    for apk in assetPKs {
        guard let r = db.one("""
            select Z_PK, ZID, ZASSETTYPE from ZJOURNALENTRYASSETMO
            where Z_PK=? and ZENTRY=?
            """, [apk, entryPK]) else {
            die("entry \(entryPK) has no asset \(apk) (see `show \(entryPK) --json` for ids)")
        }
        let t = r.s("ZASSETTYPE") ?? "?"
        guard MEDIA_TYPES.contains(t) else {
            die("asset \(apk) is type '\(t)', not media; refusing to remove it")
        }
        let au = uString(r.b("ZID"))
        db.exec("delete from ZJOURNALENTRYASSETFILEATTACHMENTMO where ZASSET=?", [apk])
        db.exec("delete from ZJOURNALENTRYASSETMO where Z_PK=?", [apk])
        if let au = au {
            gone.insert(au)
            if let eu = entryUUID {
                try? FileManager.default.removeItem(atPath: attachDir() + "/" + eu + "/" + au)
            }
        }
    }
    if !gone.isEmpty { orderingDrop(db, entryPK, gone) }
    return gone.count
}
