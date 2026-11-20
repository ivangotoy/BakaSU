#!/usr/bin/env python3
"""Repack the release APK with ksud and sign it through upstream repack_apk_multi.py, with the
signing passwords handed to apksigner as env: references (SIGN_STORE_PASSWORD, SIGN_KEY_PASSWORD)
instead of pass:<value> arguments. The values never appear in a process list or in the command
line that upstream run_cmd prints when a tool fails. Everything else (APK selection, ksud
injection, strip, zipalign, apksigner flags) is upstream's code.

repack-sign.py <workspace> <abi> <keystore> <key alias>"""
import os
import sys

ws, abi, keystore, alias = sys.argv[1:5]
for name in ("SIGN_STORE_PASSWORD", "SIGN_KEY_PASSWORD"):
    if not os.environ.get(name):
        sys.exit(f"{name} is not set")
sys.path.insert(0, ws)
import repack_apk as repack  # noqa: E402
import repack_apk_multi as multi  # noqa: E402

# placeholders stand in for the passwords on the repack_apk_multi command line
REFS = {"pass:@SIGN_STORE_PASSWORD": "env:SIGN_STORE_PASSWORD", "pass:@SIGN_KEY_PASSWORD": "env:SIGN_KEY_PASSWORD"}
used = set()
upstream_run_cmd = repack.run_cmd


def run_cmd(args, fail_msg):
    used.update(a for a in args if a in REFS)
    upstream_run_cmd([REFS.get(a, a) for a in args], fail_msg)


repack.run_cmd = run_cmd
sys.argv = ["repack_apk_multi.py", "repack", "-b", "release", "-t", "release", "-a", abi, "-K", keystore,
            "-A", alias, "-P", "@SIGN_STORE_PASSWORD", "-S", "@SIGN_KEY_PASSWORD", "--strip"]
rc = multi.main()
if rc == 0 and used != set(REFS):
    # e.g. a repack-config.json replaced the placeholders, or upstream changed how it signs
    sys.exit("apksigner did not get both passwords as env: references")
sys.exit(rc)
