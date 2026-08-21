#!/usr/bin/env python3
"""Look up photos in the macOS Photos library by capture instant + GPS.

Useful because Photos holds three things Day One does not reliably have:
the coordinates the camera recorded, Apple's reverse-geocoded place names,
and the asset's local identifier (so a Journal entry can point back at the
real photo).

Read-only: the library database is copied before any query.
"""
import os, re, shutil, sqlite3, plistlib, tempfile, datetime

CD_EPOCH = 978307200
DEFAULT_LIB = os.path.expanduser("~/Pictures/Photos Library.photoslibrary")


def find_library():
    import glob
    if os.path.isdir(DEFAULT_LIB):
        return DEFAULT_LIB
    hits = glob.glob(os.path.expanduser("~/Pictures/*.photoslibrary"))
    return hits[0] if hits else None


def connect(library=None):
    lib = library or find_library()
    if not lib:
        return None
    src = os.path.join(lib, "database", "Photos.sqlite")
    if not os.path.exists(src):
        return None
    tmp = tempfile.mkdtemp(prefix="photoslib-")
    dst = os.path.join(tmp, "Photos.sqlite")
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(src + suffix):
            shutil.copy2(src + suffix, dst + suffix)
    con = sqlite3.connect("file:%s?mode=ro" % dst, uri=True)
    con.row_factory = sqlite3.Row
    return con


def _deref(objs, ref):
    """Resolve an NSKeyedArchiver UID into its object."""
    if isinstance(ref, plistlib.UID):
        ref = ref.data
    if isinstance(ref, int) and 0 <= ref < len(objs):
        v = objs[ref]
        return None if v == "$null" else v
    return None


def parse_place(blob):
    """Pull city/state/country/street out of Photos' PLRevGeoLocationInfo."""
    if not blob:
        return {}
    try:
        objs = plistlib.loads(blob)["$objects"]
    except Exception:
        return {}
    out = {}
    for o in objs:
        if isinstance(o, dict) and "_city" in o:          # CNPostalAddress
            for key, name in (("_street", "street"), ("_city", "city"),
                              ("_state", "state"), ("_country", "country"),
                              ("_subLocality", "sublocality"),
                              ("_subAdministrativeArea", "county")):
                v = _deref(objs, o.get(key))
                if isinstance(v, str) and v.strip():
                    out[name] = v
            break
    # the most specific named place Apple assigned (a POI, park, or street)
    names = []
    for o in objs:
        if isinstance(o, dict) and "placeType" in o and "name" in o:
            v = _deref(objs, o.get("name"))
            if isinstance(v, str) and v.strip():
                names.append((o.get("placeType"), v, o.get("area") or 0))
    if names:
        smallest = min(names, key=lambda x: (x[2] if x[2] else float("inf")))
        out["place"] = smallest[1]
    return out


def match(con, wall, lat, lon, seconds=120, meters=300):
    """Find the library asset shot at this wall clock and place.

    `wall` is EXIF DateTimeOriginal -- a bare local clock reading with no
    zone attached. Rather than guess the zone (the entry's own zone is often
    wrong, which is usually *why* we are here), compare against the asset's
    own local reading: ZDATECREATED is the UTC instant and ZTIMEZONEOFFSET
    the seconds east of UTC where it was taken, so their sum is the same
    bare clock reading EXIF recorded.
    """
    if con is None or lat is None or lon is None or not wall:
        return None
    import math
    dt = datetime.datetime.strptime(wall, "%Y-%m-%d %H:%M:%S")
    target = dt.replace(tzinfo=datetime.timezone.utc).timestamp() - CD_EPOCH
    dlat = meters / 111_000.0
    dlon = meters / (111_000.0 * max(0.05, math.cos(math.radians(lat))))
    row = con.execute("""
        select z.ZUUID, z.ZLATITUDE, z.ZLONGITUDE,
               a.ZREVERSELOCATIONDATA, a.ZORIGINALFILENAME, a.ZTIMEZONENAME,
               (z.ZDATECREATED + coalesce(a.ZTIMEZONEOFFSET, 0)) local_t
        from ZASSET z
        left join ZADDITIONALASSETATTRIBUTES a on a.ZASSET = z.Z_PK
        where z.ZLATITUDE between ? and ? and z.ZLONGITUDE between ? and ?
          and z.ZTRASHEDDATE is null
          and abs(z.ZDATECREATED + coalesce(a.ZTIMEZONEOFFSET, 0) - ?) <= ?
        order by abs(z.ZDATECREATED + coalesce(a.ZTIMEZONEOFFSET, 0) - ?)
        limit 1
    """, (lat - dlat, lat + dlat, lon - dlon, lon + dlon,
          target, seconds, target)).fetchone()
    if not row:
        return None
    info = parse_place(row["ZREVERSELOCATIONDATA"])
    info.update({
        "uuid": row["ZUUID"],
        # PhotoKit's localIdentifier form, which Journal stores per asset
        "local_identifier": "%s/L0/001" % row["ZUUID"],
        "filename": row["ZORIGINALFILENAME"],
        "tz": row["ZTIMEZONENAME"],
        "lat": row["ZLATITUDE"], "lon": row["ZLONGITUDE"],
    })
    return info


def describe(info):
    """A (place, city) pair suitable for journal-cli --place/--city."""
    if not info:
        return None, None
    place = info.get("place") or info.get("street") or info.get("city")
    city = info.get("city") or info.get("county") or info.get("state")
    if place == city:
        place = info.get("street") or place
    return place, city
