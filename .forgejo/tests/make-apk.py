#!/usr/bin/env python3
"""Test fixture: write a zip with an APK signing block.

make-apk.py <out> <cert-size> [v2|v3|none] [lib ...]
The signing block holds one pair (v2 id 0x7109871A, v3 id 0xF05368C0, or none at all) whose
first signer carries a made-up certificate of <cert-size> bytes; the certificate bytes are
printed as "<size> <sha256>" so a test can compare them with apk-cert.py. Every extra argument
becomes a zip entry (e.g. lib/arm64-v8a/libkernelsu.so)."""
import hashlib
import io
import struct
import sys
import zipfile

out, size, kind = sys.argv[1], int(sys.argv[2]), sys.argv[3] if len(sys.argv) > 3 else "v2"
cert = bytes((i * 7 + 3) & 0xFF for i in range(size))


def lp(b):
    return struct.pack("<I", len(b)) + b


buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as z:
    z.writestr("AndroidManifest.xml", b"fixture")
    for name in sys.argv[4:]:
        z.writestr(name, b"fixture " + name.encode())
data = buf.getvalue()
eocd = data.rfind(b"PK\x05\x06")
cd = struct.unpack_from("<I", data, eocd + 16)[0]

if kind == "none":
    open(out, "wb").write(data)
    sys.exit(0)
digests = lp(lp(struct.pack("<I", 0x0103) + lp(b"\x00" * 32)))
signed_data = digests + lp(lp(cert)) + lp(b"")
signer = lp(signed_data) + lp(b"") + lp(b"")
value = lp(lp(signer))
pair_id = 0x7109871A if kind == "v2" else 0xF05368C0
pairs = struct.pack("<QI", 4 + len(value), pair_id) + value
block_size = len(pairs) + 8 + 16
block = struct.pack("<Q", block_size) + pairs + struct.pack("<Q", block_size) + b"APK Sig Block 42"
new_eocd = data[eocd:eocd + 16] + struct.pack("<I", cd + len(block)) + data[eocd + 20:]
open(out, "wb").write(data[:cd] + block + data[cd:eocd] + new_eocd)
print(len(cert), hashlib.sha256(cert).hexdigest())
