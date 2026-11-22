"""Write a two-frame animated GIF wider than journal-cli's resize limit.

Used by test_write.sh to check that animated images are stored unchanged.
The pixel data is LZW-encoded the simplest valid way: minimum code size 2,
with a clear code before every two pixels so every code stays 3 bits wide.
"""
import struct
import sys

W, H = 3000, 2


def lzw_block(n):
    codes = []
    for i in range(0, n, 2):
        codes += [4] + [0] * min(2, n - i)
    codes.append(5)
    acc = nb = 0
    out = bytearray()
    for c in codes:
        acc |= c << nb
        nb += 3
        while nb >= 8:
            out.append(acc & 0xFF)
            acc >>= 8
            nb -= 8
    if nb:
        out.append(acc & 0xFF)
    data = bytearray([2])
    for i in range(0, len(out), 255):
        chunk = out[i:i + 255]
        data += bytes([len(chunk)]) + chunk
    return bytes(data + b"\x00")


gif = bytearray(b"GIF89a" + struct.pack("<HHBBB", W, H, 0x80, 0, 0) + b"\x00\x00\x00\xff\xff\xff")
gif += b"\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00"
for _ in range(2):
    gif += (b"\x21\xf9\x04\x00\x0a\x00\x00\x00" + b"\x2c"
            + struct.pack("<HHHHB", 0, 0, W, H, 0) + lzw_block(W * H))
gif += b"\x3b"
with open(sys.argv[1], "wb") as fh:
    fh.write(gif)
