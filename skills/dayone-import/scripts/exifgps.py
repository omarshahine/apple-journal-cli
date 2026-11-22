#!/usr/bin/env python3
"""Minimal JPEG EXIF reader: GPS coordinates and capture time.

Deliberately dependency-free -- macOS ships no PIL and this only needs two
tags. Day One's per-entry location is whatever the *app* recorded, which for
entries written or edited after the fact is often the author's home rather
than where the photo was taken. The photo's own EXIF is the better witness.
"""
import struct


def _rational(b, off, order, n):
    """n unsigned rationals; a zero denominator is damage, not 0.0."""
    out = []
    for i in range(n):
        num, den = struct.unpack(order + "II", b[off + i * 8: off + i * 8 + 8])
        if not den:
            raise ValueError("zero denominator")
        out.append(num / den)
    return out


def _dms(tiff, entry, order, limit):
    """Degrees, minutes, seconds -> decimal degrees, or None if malformed.

    The tag must be three RATIONALs (type 5), every denominator non-zero,
    minutes and seconds under 60, and the result within `limit` degrees.
    """
    typ, cnt, val = entry
    if typ != 5 or cnt != 3 or val + 24 > len(tiff):
        return None
    try:
        d, m, s = _rational(tiff, val, order, 3)
    except (ValueError, struct.error):
        return None
    if m >= 60 or s >= 60:
        return None
    deg = d + m / 60 + s / 3600
    return deg if deg <= limit else None


def _ref(tiff, entry, allowed):
    """A GPS reference letter (ASCII, type 2), or None if absent/garbled."""
    typ, cnt, val = entry
    if typ != 2 or cnt < 1 or val >= len(tiff):
        return None
    c = tiff[val:val + 1].decode("ascii", "ignore")
    return c if c in allowed else None


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
    """-> {'lat':float,'lon':float,'when':str} for whatever could be read.

    Never raises on a damaged file: truncated or malformed metadata yields
    whatever fields were readable (possibly none), so one bad photo cannot
    abort an audit of many.
    """
    out = {}
    try:
        with open(path, "rb") as fh:
            b = fh.read(_cap)
    except OSError:
        return out
    try:
        _parse(b, out)
    except (struct.error, IndexError, ValueError, OverflowError, ZeroDivisionError):
        pass
    if "when" in out and not _valid_when(out["when"]):
        del out["when"]
    return out


def _valid_when(s):
    import datetime
    try:
        datetime.datetime.strptime(s, "%Y-%m-%d %H:%M:%S")
        return True
    except ValueError:
        return False


def _parse(b, out):
    if b[:2] != b"\xff\xd8":
        return

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
        return

    tiff = b[app1:]
    if len(tiff) < 8:
        return
    if tiff[:2] == b"II":
        order = "<"
    elif tiff[:2] == b"MM":
        order = ">"
    else:
        return
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
        return
    gps_off = struct.unpack(order + "I",
                            tiff[top[0x8825][2]:top[0x8825][2] + 4])[0]
    g = _ifd(tiff, 0, gps_off, order, {0x0001, 0x0002, 0x0003, 0x0004})
    # Both coordinates or neither: damaged GPS metadata must not yield a
    # plausible-looking location (an entry with none would take it on trust).
    # The capture time read above stands on its own and is kept.
    if not all(t in g for t in (0x0001, 0x0002, 0x0003, 0x0004)):
        return
    lat = _dms(tiff, g[0x0002], order, 90)
    lon = _dms(tiff, g[0x0004], order, 180)
    lat_ref = _ref(tiff, g[0x0001], "NS")
    lon_ref = _ref(tiff, g[0x0003], "EW")
    if None in (lat, lon, lat_ref, lon_ref):
        return
    if lat_ref == "S":
        lat = -lat
    if lon_ref == "W":
        lon = -lon
    if lat or lon:
        out["lat"], out["lon"] = lat, lon
    return


if __name__ == "__main__":
    import sys
    for p in sys.argv[1:]:
        print(p, read(p))
