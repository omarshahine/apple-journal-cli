#!/usr/bin/env python3
"""Minimal JPEG EXIF reader: GPS coordinates and capture time.

Deliberately dependency-free -- macOS ships no PIL and this only needs two
tags. Day One's per-entry location is whatever the *app* recorded, which for
entries written or edited after the fact is often the author's home rather
than where the photo was taken. The photo's own EXIF is the better witness.
"""
import struct


def _rational(b, off, order, n):
    out = []
    for i in range(n):
        num, den = struct.unpack(order + "II", b[off + i * 8: off + i * 8 + 8])
        out.append(num / den if den else 0.0)
    return out


def _ifd(b, base, off, order, want):
    """Walk one IFD, returning {tag: (type, count, value_offset_or_inline)}."""
    found = {}
    try:
        count = struct.unpack(order + "H", b[off:off + 2])[0]
    except struct.error:
        return found
    for i in range(count):
        e = off + 2 + i * 12
        if e + 12 > len(b):
            break
        tag, typ, cnt = struct.unpack(order + "HHI", b[e:e + 8])
        if tag not in want:
            continue
        size = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8}.get(typ, 1) * cnt
        if size <= 4:
            val = e + 8
        else:
            val = base + struct.unpack(order + "I", b[e + 8:e + 12])[0]
        found[tag] = (typ, cnt, val)
    return found


def read(path, _cap=384 * 1024):
    """-> {'lat':float,'lon':float,'when':str} for whatever could be read."""
    out = {}
    try:
        with open(path, "rb") as fh:
            b = fh.read(_cap)
    except OSError:
        return out
    if b[:2] != b"\xff\xd8":
        return out

    # locate the APP1/Exif segment
    i, app1 = 2, None
    while i + 4 < len(b):
        if b[i] != 0xFF:
            break
        marker, seglen = b[i + 1], struct.unpack(">H", b[i + 2:i + 4])[0]
        if marker == 0xE1 and b[i + 4:i + 10] == b"Exif\x00\x00":
            app1 = i + 10
            break
        if marker in (0xD8, 0xD9) or seglen < 2:
            break
        i += 2 + seglen
    if app1 is None:
        return out

    tiff = b[app1:]
    if tiff[:2] == b"II":
        order = "<"
    elif tiff[:2] == b"MM":
        order = ">"
    else:
        return out
    ifd0 = struct.unpack(order + "I", tiff[4:8])[0]

    top = _ifd(tiff, 0, ifd0, order, {0x8825, 0x8769})

    if 0x8769 in top:                                   # Exif sub-IFD
        exif_off = struct.unpack(
            order + "I", tiff[top[0x8769][2]:top[0x8769][2] + 4])[0] \
            if top[0x8769][1] == 1 and top[0x8769][0] == 4 else None
        if exif_off:
            sub = _ifd(tiff, 0, exif_off, order, {0x9003})
            if 0x9003 in sub:
                _t, cnt, val = sub[0x9003]
                s = tiff[val:val + cnt].split(b"\x00")[0].decode("ascii", "ignore")
                if len(s) >= 19:
                    out["when"] = "%s %s" % (s[:10].replace(":", "-"), s[11:19])

    if 0x8825 not in top:                               # GPS IFD
        return out
    gps_off = struct.unpack(order + "I",
                            tiff[top[0x8825][2]:top[0x8825][2] + 4])[0]
    g = _ifd(tiff, 0, gps_off, order, {0x0001, 0x0002, 0x0003, 0x0004})
    if 0x0002 not in g or 0x0004 not in g:
        return out
    try:
        lat = _rational(tiff, g[0x0002][2], order, 3)
        lon = _rational(tiff, g[0x0004][2], order, 3)
    except struct.error:
        return out
    lat = lat[0] + lat[1] / 60 + lat[2] / 3600
    lon = lon[0] + lon[1] / 60 + lon[2] / 3600
    if 0x0001 in g and tiff[g[0x0001][2]:g[0x0001][2] + 1] in (b"S",):
        lat = -lat
    if 0x0003 in g and tiff[g[0x0003][2]:g[0x0003][2] + 1] in (b"W",):
        lon = -lon
    if lat or lon:
        out["lat"], out["lon"] = lat, lon
    return out


if __name__ == "__main__":
    import sys
    for p in sys.argv[1:]:
        print(p, read(p))
