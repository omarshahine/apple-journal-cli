// WriteCommands.swift — write, edit, delete, restore, empty, sandbox.
import Foundation

// Journal stores entry text as RTF and renders its formatting, so callers
// that already have styled text can hand it over verbatim instead of having
// it flattened through textToRTF.
private func readBodyRTF(_ a: Args) -> (data: Data, plain: String)? {
    // Markdown is rendered into Journal's own rich text; Journal shows no
    // Markdown syntax, so leaving it in place would print it literally.
    if a.has("--markdown"), let md = readBody(a) { return markdownToRTF(md) }
    guard let path = a.value("--body-rtf") else { return nil }
    let full = (path as NSString).expandingTildeInPath
    guard let d = FileManager.default.contents(atPath: full) else {
        die("cannot read --body-rtf file: \(path)")
    }
    guard let att = NSAttributedString(rtf: d, documentAttributes: nil) else {
        die("--body-rtf is not valid RTF: \(path)")
    }
    return (d, att.string)
}

private func readBody(_ a: Args) -> String? {
    if let b = a.value("--body") { return b }
    if let f = a.value("--body-file") {
        return (try? String(contentsOfFile: f, encoding: .utf8)) ?? ""
    }
    // stdin only when it is a pipe or redirected file; a tty or /dev/null would block
    var st = stat()
    if fstat(0, &st) == 0 {
        let mode = st.st_mode & S_IFMT
        if mode == S_IFIFO || mode == S_IFREG {
            let d = FileHandle.standardInput.readDataToEndOfFile()
            // an empty pipe/file (CI runners, `< /dev/null`-less shells) is no input
            if d.isEmpty { return nil }
            return String(data: d, encoding: .utf8)
        }
    }
    return nil
}

// Render Markdown the way `write --markdown` would, without touching a store.
// Lets callers compare an entry's stored text against what it *should* be,
// which is exact where sniffing for leftover syntax is guesswork.
func cmdRender(_ a: Args) {
    let md = readBody(a) ?? ""
    if a.has("--plain") {
        FileHandle.standardOutput.write(Data(markdownToPlain(md).utf8))
    } else {
        FileHandle.standardOutput.write(markdownToRTF(md).data)
    }
}

func cmdWrite(_ a: Args) {
    let rtfBody = readBodyRTF(a)
    let body = rtfBody?.plain ?? (readBody(a) ?? "")
    let media = a.values("--media").map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }
    for m in media where !FileManager.default.fileExists(atPath: m) {
        die("media file not found: \(m)")
    }
    var lp: [String]? = nil
    let lpArgs = a.values("--live-photo")
    if !lpArgs.isEmpty {
        guard lpArgs.count == 2 else { die("--live-photo takes IMAGE then VIDEO (e.g. IMG.heic IMG.mov)") }
        let pair = lpArgs.map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }
        guard PHOTO_EXT.contains(ext(pair[0])), VIDEO_EXT.contains(ext(pair[1])) else {
            die("--live-photo takes IMAGE then VIDEO (e.g. IMG.heic IMG.mov)")
        }
        for x in pair where !FileManager.default.fileExists(atPath: x) {
            die("live-photo file not found: \(x)")
        }
        lp = pair
    }
    let lat = a.double("--lat"), lon = a.double("--lon")
    let hasLoc = lat != nil || lon != nil
    if hasLoc && (lat == nil || lon == nil) { die("--lat and --lon must be given together") }
    let link = a.value("--link")
    let hasText = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if !hasText && media.isEmpty && lp == nil && !hasLoc && link == nil {
        die("nothing to write (need --body/--body-file/stdin, --media, --live-photo, --link, or --lat/--lon)")
    }

    let when = a.value("--date").map(parseDate) ?? Date()
    let ts = cd(when)
    let entryUUID = uid()
    let title = a.value("--title").map { a.has("--markdown") ? markdownToPlain($0) : $0 }

    if a.has("--dry-run") {
        var bits: [String] = []
        if hasText { bits.append("\(body.count) chars") }
        if !media.isEmpty { bits.append("\(media.count) media") }
        if lp != nil { bits.append("1 live photo") }
        if link != nil { bits.append("1 link") }
        if hasLoc { bits.append(String(format: "location %.5f,%.5f", lat!, lon!)) }
        if let j = a.value("--journal") { bits.append("journal '\(j)'") }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        print("DRY RUN: would create entry (\(bits.isEmpty ? "empty" : bits.joined(separator: ", "))) dated \(f.string(from: when)). Nothing written.")
        return
    }
    let pk: Int64 = withLive(allowLiveDefault: a.has("--live"), acceptRisk: a.has("--accept-risk")) { db in
        let (ent, pk) = nextPK(db, "JournalEntryMO")
        db.exec("""
            insert into ZJOURNALENTRYMO
              (Z_PK, Z_ENT, Z_OPT, ZENTRYTYPE, ZID,
               ZENTRYDATE, ZCREATEDDATE, ZUPDATEDDATE, ZMOMENTDATEFORSORTING,
               ZTEXT, ZTITLE, ZTEXTLENGTH, ZSHOWTITLE,
               ZISDRAFT, ZFLAGGED, ZISUPLOADEDTOCLOUD, ZISREMOVEDFROMCLOUD,
               ZISFULLYREMOVED, ZRECENTLYDELETED, ZISTIP,
               ZMINIMUMSUPPORTEDAPPVERSION, ZMINIMUMSUPPORTEDAPPVERSIONMODE)
            values (?,?,1,'blankEntry',?, ?,?,?,?, ?,?,?,?, 0,?,0,0, 0,0,0, 0,0)
            """, [pk, ent, uidBytes(entryUUID), ts, cdNow(), cdNow(), ts,
                  hasText ? (rtfBody?.data ?? textToRTF(body)) : nil,
                  title.map(textToRTF),
                  body.count, title != nil ? 1 : 0,
                  a.has("--bookmark") ? 1 : 0])

        var ordering: [String] = []
        for m in media {
            let atype = VIDEO_EXT.contains(ext(m)) ? "video" : "photo"
            var meta: [String: Any] = ["date": ts]
            if hasLoc {
                meta["latitude"] = lat!; meta["longitude"] = lon!
                if let p = a.value("--place") { meta["placeName"] = p }
            }
            if a.has("--photos-link") {
                if let aid = photosLookup(m) { meta["assetIdentifier"] = aid }
                else {
                    FileHandle.standardError.write(
                        "warning: no Photos-library match for \(URL(fileURLWithPath: m).lastPathComponent)\n"
                            .data(using: .utf8)!)
                }
            }
            let (apk, au) = addAsset(db, entryPK: pk, entryUUID: entryUUID,
                                     type: atype, source: "imagePicker", metadata: meta)
            addFile(db, assetPK: apk, assetUUID: au, entryUUID: entryUUID,
                    srcPath: m, index: 0, resize: !a.has("--no-resize"))
            ordering.append(au)
        }
        if let lp = lp {
            var meta: [String: Any] = ["date": ts]
            if a.has("--photos-link"), let aid = photosLookup(lp[0]) {
                meta["assetIdentifier"] = aid
            }
            let (apk, au) = addAsset(db, entryPK: pk, entryUUID: entryUUID,
                                     type: "livePhoto", source: "imagePicker", metadata: meta)
            addFile(db, assetPK: apk, assetUUID: au, entryUUID: entryUUID,
                    srcPath: lp[0], index: 0, resize: false, plainName: true)
            addFile(db, assetPK: apk, assetUUID: au, entryUUID: entryUUID,
                    srcPath: lp[1], index: 0, resize: false, plainName: true)
            ordering.append(au)
        }
        if let link = link {
            let payload = makeLinkPayload(link, title: a.value("--link-title"))
            let (apk, au) = addAsset(db, entryPK: pk, entryUUID: entryUUID,
                                     type: "link", source: "shareSheet",
                                     metadata: ["data": payload, "date": cdNow()])
            db.exec("update ZJOURNALENTRYASSETMO set ZCONTENTTYPE='unknown' where Z_PK=?", [apk])
            ordering.append(au)
        }
        if hasLoc {
            var visit: [String: Any] = ["latitude": lat!, "longitude": lon!,
                                        "createdDate": cdNow(),
                                        "visitStartTime": ts, "visitEndTime": ts,
                                        "horizontalAccuracy": 0, "confidenceLevel": 0,
                                        "assetSource": "locationPicker"]
            if let p = a.value("--place") { visit["placeName"] = p }
            if let c = a.value("--city") { visit["city"] = c }
            let (_, au) = addAsset(db, entryPK: pk, entryUUID: entryUUID,
                                   type: "multiPinMap", source: "locationPicker",
                                   metadata: ["revision": 2, "visitsData": [visit]], slim: 1)
            ordering.append(au)
        }
        if !ordering.isEmpty { orderingAppend(db, pk, ordering) }

        if let jsel = a.value("--journal") {
            let j = resolveJournal(db, jsel)
            if !j.isDefault {
                db.exec("insert or ignore into Z_5JOURNALS (Z_5ENTRIES, Z_6JOURNALS) values (?,?)",
                        [pk, j.pk])
            }
        }
        return pk
    }

    var bits: [String] = []
    if hasText { bits.append("\(body.count) chars") }
    if !media.isEmpty { bits.append("\(media.count) media") }
    if lp != nil { bits.append("1 live photo") }
    if link != nil { bits.append("1 link") }
    if hasLoc { bits.append(String(format: "location %.5f,%.5f", lat!, lon!)) }
    if let j = a.value("--journal") { bits.append("journal '\(j)'") }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
    print("Created entry \(pk) (\(bits.isEmpty ? "empty" : bits.joined(separator: ", "))) dated \(f.string(from: when)).")
    if a.has("--live") {
        FileHandle.standardError.write(
            "Marked unsynced; Journal.app should upload it on next launch.\n".data(using: .utf8)!)
    }
}

func cmdEdit(_ a: Args) {
    let rtfBody = readBodyRTF(a)
    guard let idStr = a.positional.first, let pk = Int64(idStr) else { die("edit needs an entry id") }
    let body = rtfBody?.plain ?? readBody(a)
    let title = a.value("--title").map { a.has("--markdown") ? markdownToPlain($0) : $0 }
    let media = a.values("--add-media").map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }
    for m in media where !FileManager.default.fileExists(atPath: m) {
        die("media file not found: \(m)")
    }
    let lat = a.double("--lat"), lon = a.double("--lon")
    let hasLoc = lat != nil || lon != nil
    if hasLoc && (lat == nil || lon == nil) { die("--lat and --lon must be given together") }
    let bookmark: Bool? = a.has("--bookmark") ? true : (a.has("--no-bookmark") ? false : nil)
    let touchesText = body != nil || title != nil
    let removeMedia = a.values("--remove-media").compactMap { Int64($0) }
    let addLink = a.value("--add-link")

    if !(touchesText || !media.isEmpty || hasLoc || a.has("--clear-location")
         || !removeMedia.isEmpty || a.has("--remove-all-media") || addLink != nil
         || a.value("--journal") != nil || a.value("--date") != nil || bookmark != nil) {
        die("nothing to change")
    }

    if a.has("--dry-run") {
        let exists = withSnapshot { db in
            db.one("select Z_PK from ZJOURNALENTRYMO where Z_PK=?", [pk]) != nil }
        if !exists { die("no entry with id \(pk)") }
        print("DRY RUN: would update entry \(pk). Nothing written.")
        return
    }
    var removed = 0
    withLive(allowLiveDefault: a.has("--live"), acceptRisk: a.has("--accept-risk")) { db in
        guard let row = db.one("""
            select Z_PK, ZID, ZMERGEABLEATTRIBUTES from ZJOURNALENTRYMO where Z_PK=?
            """, [pk]) else { die("no entry with id \(pk)") }
        let entryUUID = uString(row.b("ZID"))

        if touchesText, row.b("ZMERGEABLEATTRIBUTES") != nil, !a.has("--force") {
            die("entry \(pk) carries a ZMERGEABLEATTRIBUTES CRDT (Journal's merge copy\n"
                + "  of the text). Editing ZTEXT alone can be reverted or duplicated on sync.\n"
                + "  Change location/media/date/bookmark freely, edit the text in Journal.app,\n"
                + "  or pass --force to write ZTEXT anyway.")
        }

        var sets: [String] = []
        var vals: [Any?] = []
        if let b = body {
            let blank = b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            sets += ["ZTEXT=?", "ZTEXTLENGTH=?"]
            vals += [blank ? nil : (rtfBody?.data ?? textToRTF(b)), b.count]
        }
        if let t = title {
            let empty = t.trimmingCharacters(in: .whitespaces).isEmpty
            sets += ["ZTITLE=?", "ZSHOWTITLE=?"]
            vals += [empty ? nil : textToRTF(t), empty ? 0 : 1]
        }
        if let dstr = a.value("--date") {
            let ts = cd(parseDate(dstr))
            sets += ["ZENTRYDATE=?", "ZMOMENTDATEFORSORTING=?"]; vals += [ts, ts]
        }
        if let bm = bookmark { sets += ["ZFLAGGED=?"]; vals += [bm ? 1 : 0] }
        sets += ["ZUPDATEDDATE=?", "ZENTRYDATAUPDATEDATE=?", "ZISUPLOADEDTOCLOUD=0"]
        vals += [cdNow(), cdNow()]
        vals.append(pk)
        db.exec("update ZJOURNALENTRYMO set \(sets.joined(separator: ", ")) where Z_PK=?", vals)

        if a.has("--clear-location") || hasLoc {
            var gone: Set<String> = []
            for r in db.query("""
                select Z_PK, ZID from ZJOURNALENTRYASSETMO
                where ZENTRY=? and ZASSETTYPE in ('multiPinMap','genericMap')
                """, [pk]) {
                if let au = uString(r.b("ZID")) { gone.insert(au) }
                db.exec("delete from ZJOURNALENTRYASSETFILEATTACHMENTMO where ZASSET=?", [r.i("Z_PK") ?? 0])
                db.exec("delete from ZJOURNALENTRYASSETMO where Z_PK=?", [r.i("Z_PK") ?? 0])
            }
            if !gone.isEmpty { orderingDrop(db, pk, gone) }
        }

        if a.has("--remove-all-media") {
            let pks = db.query("""
                select Z_PK from ZJOURNALENTRYASSETMO
                where ZENTRY=? and ZASSETTYPE in ('photo','video','livePhoto')
                """, [pk]).compactMap { $0.i("Z_PK") }
            removed = removeAssets(db, entryPK: pk, entryUUID: entryUUID, assetPKs: pks)
        } else if !removeMedia.isEmpty {
            removed = removeAssets(db, entryPK: pk, entryUUID: entryUUID, assetPKs: removeMedia)
        }

        var added: [String] = []
        for m in media {
            let atype = VIDEO_EXT.contains(ext(m)) ? "video" : "photo"
            var meta: [String: Any] = ["date": cdNow()]
            if a.has("--photos-link") {
                if let aid = photosLookup(m) { meta["assetIdentifier"] = aid }
                else {
                    FileHandle.standardError.write(
                        "warning: no Photos-library match for \(URL(fileURLWithPath: m).lastPathComponent)\n"
                            .data(using: .utf8)!)
                }
            }
            let (apk, au) = addAsset(db, entryPK: pk, entryUUID: entryUUID ?? uid(),
                                     type: atype, source: "imagePicker", metadata: meta)
            addFile(db, assetPK: apk, assetUUID: au, entryUUID: entryUUID ?? "",
                    srcPath: m, index: 0, resize: !a.has("--no-resize"))
            added.append(au)
        }
        if let link = addLink {
            let payload = makeLinkPayload(link, title: a.value("--link-title"))
            let (apk, au) = addAsset(db, entryPK: pk, entryUUID: entryUUID ?? uid(),
                                     type: "link", source: "shareSheet",
                                     metadata: ["data": payload, "date": cdNow()])
            db.exec("update ZJOURNALENTRYASSETMO set ZCONTENTTYPE='unknown' where Z_PK=?", [apk])
            added.append(au)
        }
        if hasLoc {
            let ets = db.one("select ZENTRYDATE from ZJOURNALENTRYMO where Z_PK=?", [pk])?
                .d("ZENTRYDATE") ?? cdNow()
            var visit: [String: Any] = ["latitude": lat!, "longitude": lon!,
                                        "createdDate": cdNow(),
                                        "visitStartTime": ets, "visitEndTime": ets,
                                        "horizontalAccuracy": 0, "confidenceLevel": 0,
                                        "assetSource": "locationPicker"]
            if let p = a.value("--place") { visit["placeName"] = p }
            if let c = a.value("--city") { visit["city"] = c }
            let (_, au) = addAsset(db, entryPK: pk, entryUUID: entryUUID ?? uid(),
                                   type: "multiPinMap", source: "locationPicker",
                                   metadata: ["revision": 2, "visitsData": [visit]], slim: 1)
            added.append(au)
        }
        if !added.isEmpty { orderingAppend(db, pk, added) }

        if let jsel = a.value("--journal") {
            let j = resolveJournal(db, jsel)
            db.exec("delete from Z_5JOURNALS where Z_5ENTRIES=?", [pk])
            if !j.isDefault {
                db.exec("insert into Z_5JOURNALS (Z_5ENTRIES, Z_6JOURNALS) values (?,?)", [pk, j.pk])
            }
        }
    }

    var bits: [String] = []
    if body != nil { bits.append("body") }
    if title != nil { bits.append("title") }
    if a.value("--date") != nil { bits.append("date") }
    if let bm = bookmark { bits.append("bookmark=\(bm)") }
    if a.has("--clear-location") && !hasLoc { bits.append("location cleared") }
    if hasLoc { bits.append("location set") }
    if !media.isEmpty { bits.append("\(media.count) media added") }
    if !removeMedia.isEmpty || a.has("--remove-all-media") { bits.append("\(removed) media removed") }
    if addLink != nil { bits.append("1 link added") }
    if let j = a.value("--journal") { bits.append("moved to journal '\(j)'") }
    print("Updated entry \(pk) (\(bits.joined(separator: ", "))).")
}

func cmdDelete(_ a: Args) {
    guard let idStr = a.positional.first, let pk = Int64(idStr) else { die("delete needs an entry id") }
    if a.has("--dry-run") {
        let exists = withSnapshot { db in
            db.one("select Z_PK from ZJOURNALENTRYMO where Z_PK=?", [pk]) != nil }
        if !exists { die("no entry with id \(pk)") }
        print("DRY RUN: would \(a.has("--hard") ? "hard-delete" : "soft-delete") entry \(pk). Nothing written.")
        return
    }
    let what: String = withLive(allowLiveDefault: a.has("--live"), acceptRisk: a.has("--accept-risk")) { db in
        guard let row = db.one("""
            select Z_PK, ZID, ZISUPLOADEDTOCLOUD from ZJOURNALENTRYMO where Z_PK=?
            """, [pk]) else { die("no entry with id \(pk)") }
        if a.has("--hard") && row.flag("ZISUPLOADEDTOCLOUD") && !a.has("--force") {
            die("entry \(pk) has synced to iCloud. A local hard delete does not\n"
                + "  tombstone the CloudKit record, and the entry RESURRECTS on the next\n"
                + "  sync (verified). Use a soft delete (no --hard), delete it in\n"
                + "  Journal.app, or pass --force if you accept the resurrection risk.")
        }
        if a.has("--hard") {
            let apks = db.query("select Z_PK from ZJOURNALENTRYASSETMO where ZENTRY=?", [pk])
                .compactMap { $0.i("Z_PK") }
            for apk in apks {
                db.exec("delete from ZJOURNALENTRYASSETFILEATTACHMENTMO where ZASSET=?", [apk])
            }
            db.exec("delete from ZJOURNALENTRYASSETMO where ZENTRY=?", [pk])
            db.exec("delete from Z_5JOURNALS where Z_5ENTRIES=?", [pk])
            db.exec("delete from ZJOURNALENTRYMO where Z_PK=?", [pk])
            if let eu = uString(row.b("ZID")) {
                try? FileManager.default.removeItem(atPath: attachDir() + "/" + eu)
            }
            return "hard-deleted (with \(apks.count) assets)"
        } else {
            db.exec("""
                update ZJOURNALENTRYMO
                set ZRECENTLYDELETED=1, ZRECENTLYDELETEDENTRYDATE=?, ZUPDATEDDATE=?,
                    ZISUPLOADEDTOCLOUD=0
                where Z_PK=?
                """, [cdNow(), cdNow(), pk])
            return "marked deleted (Recently Deleted); deletion will sync"
        }
    }
    print("Entry \(pk) \(what).")
}

func cmdRestore(_ a: Args) {
    guard let idStr = a.positional.first, let pk = Int64(idStr) else { die("restore needs an entry id") }
    if a.has("--dry-run") {
        print("DRY RUN: would restore entry \(pk). Nothing written.")
        return
    }
    withLive(allowLiveDefault: a.has("--live"), acceptRisk: a.has("--accept-risk")) { db in
        guard let row = db.one("""
            select Z_PK, ZRECENTLYDELETED from ZJOURNALENTRYMO where Z_PK=?
            """, [pk]) else { die("no entry with id \(pk)") }
        guard row.flag("ZRECENTLYDELETED") else { die("entry \(pk) is not in Recently Deleted") }
        db.exec("""
            update ZJOURNALENTRYMO
            set ZRECENTLYDELETED=0, ZRECENTLYDELETEDENTRYDATE=NULL,
                ZUPDATEDDATE=?, ZISUPLOADEDTOCLOUD=0
            where Z_PK=?
            """, [cdNow(), pk])
    }
    print("Entry \(pk) restored; the restore will sync.")
}

func cmdEmpty(_ a: Args) {
    if a.has("--dry-run") {
        let n: Int = withSnapshot { db in
            db.query("""
                select Z_PK from ZJOURNALENTRYMO
                where coalesce(ZRECENTLYDELETED,0)=1 and coalesce(ZISFULLYREMOVED,0)=0
                """).count }
        print("DRY RUN: would consider \(n) Recently Deleted entr\(n == 1 ? "y" : "ies"). Nothing written.")
        return
    }
    var purged = 0, skipped = 0
    withLive(allowLiveDefault: a.has("--live"), acceptRisk: a.has("--accept-risk")) { db in
        for r in db.query("""
            select Z_PK, ZID, ZISUPLOADEDTOCLOUD from ZJOURNALENTRYMO
            where coalesce(ZRECENTLYDELETED,0)=1 and coalesce(ZISFULLYREMOVED,0)=0
            """) {
            if r.flag("ZISUPLOADEDTOCLOUD") && !a.has("--force") { skipped += 1; continue }
            let pk = r.i("Z_PK") ?? 0
            for apk in db.query("select Z_PK from ZJOURNALENTRYASSETMO where ZENTRY=?", [pk])
                .compactMap({ $0.i("Z_PK") }) {
                db.exec("delete from ZJOURNALENTRYASSETFILEATTACHMENTMO where ZASSET=?", [apk])
            }
            db.exec("delete from ZJOURNALENTRYASSETMO where ZENTRY=?", [pk])
            db.exec("delete from Z_5JOURNALS where Z_5ENTRIES=?", [pk])
            db.exec("delete from ZJOURNALENTRYMO where Z_PK=?", [pk])
            if let eu = uString(r.b("ZID")) {
                try? FileManager.default.removeItem(atPath: attachDir() + "/" + eu)
            }
            purged += 1
        }
    }
    var msg = "Purged \(purged) entr\(purged == 1 ? "y" : "ies")."
    if skipped > 0 {
        msg += " Skipped \(skipped) synced entr\(skipped == 1 ? "y" : "ies"):"
            + " a local purge of synced entries resurrects them from iCloud."
            + " Empty Recently Deleted in Journal.app instead (or --force to purge anyway)."
    }
    print(msg)
}

func cmdSandbox(_ a: Args) {
    guard let dir = a.value("--dir") else { die("sandbox needs --dir") }
    let src = a.value("--from").map { ($0 as NSString).expandingTildeInPath } ?? DEFAULT_DB
    guard FileManager.default.fileExists(atPath: src) else { die("source store not found: \(src)") }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let base = "moments.sqlite"
    for suf in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: src + suf) {
        try? FileManager.default.removeItem(atPath: dir + "/" + base + suf)
        do { try FileManager.default.copyItem(atPath: src + suf, toPath: dir + "/" + base + suf) }
        catch {
            die("permission denied reading \(src)\n"
                + "  Grant Full Disk Access, or seed from a backup with --from.")
        }
    }
    try? FileManager.default.createDirectory(atPath: dir + "/Attachments",
                                             withIntermediateDirectories: true)
    print(dir + "/" + base)
}
