// Media.swift — image resizing (ImageIO), Photos-library lookup, link payloads.
import Foundation
import ImageIO
import UniformTypeIdentifiers
import LinkPresentation

let RESIZE_MAX = 2830 // long edge of Journal's own _resized derivatives (~6MP)
let PHOTO_EXT: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "gif", "tiff", "webp"]
let VIDEO_EXT: Set<String> = ["mov", "mp4", "m4v", "avi"]

func ext(_ path: String) -> String {
    URL(fileURLWithPath: path).pathExtension.lowercased()
}

func imageDims(_ path: String) -> (Int, Int) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int else { return (0, 0) }
    return (w, h)
}

/// Copy src to dst, downscaling to RESIZE_MAX long edge like Journal does.
@discardableResult
func resizeInto(_ src: String, _ dst: String) -> Bool {
    let (w, h) = imageDims(src)
    if max(w, h) > RESIZE_MAX,
       let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: src) as CFURL, nil),
       let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
           kCGImageSourceCreateThumbnailFromImageAlways: true,
           kCGImageSourceThumbnailMaxPixelSize: RESIZE_MAX,
           kCGImageSourceCreateThumbnailWithTransform: true,
       ] as CFDictionary) {
        let type = UTType(filenameExtension: ext(dst))?.identifier ?? UTType.jpeg.identifier
        if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dst) as CFURL,
                                                      type as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, thumb,
                [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(dest) { return true }
        }
    }
    try? FileManager.default.removeItem(atPath: dst)
    try? FileManager.default.copyItem(atPath: src, toPath: dst)
    return false
}

// ---------------------------------------------------------------- Photos library

var PHOTOS_DB: String { NSHomeDirectory() + "/Pictures/Photos Library.photoslibrary/database/Photos.sqlite" }

/// Best-effort PHAsset localIdentifier ("UUID/L0/001") for a media file.
func photosLookup(_ path: String) -> String? {
    let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    if path.contains(".photoslibrary/"), UUID(uuidString: stem) != nil {
        return "\(stem.uppercased())/L0/001"
    }
    guard FileManager.default.fileExists(atPath: PHOTOS_DB) else { return nil }
    var h: OpaquePointer?
    guard sqlite3_open_v2(PHOTOS_DB, &h,
                          SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let h = h else { return nil }
    defer { sqlite3_close(h) }
    var stmt: OpaquePointer?
    let sql = """
        select a.ZUUID, aa.ZORIGINALFILESIZE from ZASSET a
        join ZADDITIONALASSETATTRIBUTES aa on aa.ZASSET=a.Z_PK
        where aa.ZORIGINALFILENAME=?
        """
    guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    let name = URL(fileURLWithPath: path).lastPathComponent
    sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    var rows: [(String, Int64)] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let u = sqlite3_column_text(stmt, 0) else { continue }
        rows.append((String(cString: u), sqlite3_column_int64(stmt, 1)))
    }
    if rows.count == 1 { return "\(rows[0].0)/L0/001" }
    if rows.count > 1, let attrs = try? FileManager.default.attributesOfItem(atPath: path),
       let size = attrs[.size] as? Int64 {
        let hits = rows.filter { $0.1 == size }
        if hits.count == 1 { return "\(hits[0].0)/L0/001" }
    }
    return nil
}

import SQLite3

// ---------------------------------------------------------------- links

/// base64 NSKeyedArchiver LPLinkMetadata, the format Journal's link assets use.
func makeLinkPayload(_ urlString: String, title: String?) -> String {
    guard let u = URL(string: urlString),
          let scheme = u.scheme, ["http", "https"].contains(scheme), u.host != nil else {
        die("--link needs an absolute http(s) URL, got '\(urlString)'")
    }
    let md = LPLinkMetadata()
    md.originalURL = u
    md.url = u
    if let t = title { md.title = t }
    guard let data = try? NSKeyedArchiver.archivedData(withRootObject: md,
                                                       requiringSecureCoding: true) else {
        die("could not build link metadata for '\(urlString)'")
    }
    return data.base64EncodedString()
}

/// Pull url/title back out of a link asset's archived LPLinkMetadata.
func decodeLinkPayload(_ meta: [String: Any]) -> (String?, String?) {
    guard let b64 = meta["data"] as? String,
          let raw = Data(base64Encoded: b64),
          let md = try? NSKeyedUnarchiver.unarchivedObject(ofClass: LPLinkMetadata.self,
                                                           from: raw) else { return (nil, nil) }
    return ((md.url ?? md.originalURL)?.absoluteString, md.title)
}
