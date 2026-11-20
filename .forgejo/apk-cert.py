#!/usr/bin/env python3
"""Print "<size> <sha256>" of an APK's signing certificate as KernelSU reads it: the first
certificate of the first signer in the APK signature scheme v2 block (kernel/manager/apk_sign.c,
ksud apk_sign::get_apk_signature). The size is the DER length; the kernel prints it as hex."""
import hashlib
import struct
import sys

d = open(sys.argv[1], "rb").read()
eocd = d.rfind(b"PK\x05\x06")
if eocd < 0:
    sys.exit("no end of central directory")
cd = struct.unpack_from("<I", d, eocd + 16)[0]
if d[cd - 16:cd] != b"APK Sig Block 42":
    sys.exit("no APK signing block")
p, end = cd - struct.unpack_from("<Q", d, cd - 24)[0], cd - 24
while p < end:
    n, block_id = struct.unpack_from("<QI", d, p)
    if block_id == 0x7109871A:
        q = p + 12 + 4 + 4 + 4  # signers length, first signer length, signed data length
        q += 4 + struct.unpack_from("<I", d, q)[0]  # digests
        q += 4  # certificates length
        size = struct.unpack_from("<I", d, q)[0]
        cert = d[q + 4:q + 4 + size]
        print(len(cert), hashlib.sha256(cert).hexdigest())
        sys.exit(0)
    p += 8 + n
sys.exit("no v2 signature")
