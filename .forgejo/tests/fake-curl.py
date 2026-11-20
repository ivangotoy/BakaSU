#!/usr/bin/env python3
"""Test stub for curl: a fake Forgejo release API kept in files under $FAKE_FORGE.

Understands the curl calls of .forgejo/manager-ci.sh (-X, -H, -d, -F name=@file, -o, -w,
--fail-with-body, -L). Every call is appended to $FAKE_FORGE/argv.log (one JSON list per line).
State: releases.json, tags.json, assets/<id>. Fault injection (environment):
  FAKE_FAIL="<METHOD> <path suffix>"        fail that request before it is applied
  FAKE_LOSE_REPLY="<METHOD> <path suffix>"  apply that request, then fail as if the reply was lost
  FAKE_CORRUPT_DOWNLOAD=1                   attachment downloads return other bytes
  FAKE_ASSET_URL=<url>                      browser_download_url to report"""
import json
import os
import re
import sys

forge = os.environ["FAKE_FORGE"]
argv = sys.argv[1:]
with open(os.path.join(forge, "argv.log"), "a") as f:
    f.write(json.dumps(argv) + "\n")


def load(name, default):
    p = os.path.join(forge, name)
    return json.load(open(p)) if os.path.exists(p) else default


def save(name, value):
    json.dump(value, open(os.path.join(forge, name), "w"))


method, headers, data, form, out, wfmt, fail_body = "GET", [], None, None, None, None, False
url, i = None, 0
while i < len(argv):
    a = argv[i]
    if a in ("-X", "-H", "-d", "-F", "-o", "-w", "--connect-timeout", "--max-time", "--retry"):
        v = argv[i + 1]
        i += 2
        if a == "-X":
            method = v
        elif a == "-H":
            headers.append(v)
        elif a == "-d":
            data = v
        elif a == "-F":
            form = v
        elif a == "-o":
            out = v
        elif a == "-w":
            wfmt = v
        continue
    if a == "--fail-with-body":
        fail_body = True
    elif not a.startswith("-"):
        url = a
    i += 1

server = os.environ["FAKE_SERVER_URL"]
auth = None
for h in headers:
    if h.startswith("@"):
        for line in open(h[1:]):
            if line.lower().startswith("authorization:"):
                auth = line.split(":", 1)[1].strip()
if auth != "token " + os.environ["FAKE_TOKEN"]:
    sys.stderr.write("fake-curl: missing or wrong authorization header\n")
    sys.exit(22)


def reply(code, body=b""):
    if isinstance(body, (dict, list)):
        body = json.dumps(body).encode()
    if out and out != "/dev/null":
        open(out, "wb").write(body)
    elif not out:
        sys.stdout.buffer.write(body)
    if wfmt:
        sys.stdout.write(wfmt.replace("%{http_code}", str(code)))
    sys.exit(22 if fail_body and code >= 400 else 0)


def fault(var):
    spec = os.environ.get(var, "")
    if not spec:
        return False
    m, _, suffix = spec.partition(" ")
    return m == method and path.split("?")[0].endswith(suffix)


releases, tags = load("releases.json", {}), load("tags.json", {})
if url.startswith(server + "/") and "/api/v1/" not in url:  # attachment download: .../<asset id>
    path = url[len(server):]
    aid = url.rsplit("/", 1)[1]
    body = open(os.path.join(forge, "assets", aid), "rb").read()
    reply(200, b"corrupt" + body if os.environ.get("FAKE_CORRUPT_DOWNLOAD") else body)
m = re.match(re.escape(server) + r"/api/v1/repos/[^/]+/[^/]+(/.*)$", url or "")
if not m:
    reply(404)
path = m.group(1)
if fault("FAKE_FAIL"):
    sys.exit(28)
lose = fault("FAKE_LOSE_REPLY")

route = path.split("?")[0].split("/")[1:]
code, body = 404, {"message": "not found"}
if route[:2] == ["releases", "tags"] and method == "GET":
    hit = [r for r in releases.values() if r["tag_name"] == route[2]]
    code, body = (200, hit[0]) if hit else (404, body)
elif route == ["tags", route[-1]] and method == "GET":
    if route[1] in tags:
        code, body = 200, {"name": route[1], "commit": {"sha": tags[route[1]]}}
elif route == ["releases"] and method == "POST":
    req = json.loads(data)
    rid = str(len(releases) + 7)
    releases[rid] = dict(req, id=int(rid))
    code, body = 201, releases[rid]
elif len(route) == 2 and route[0] == "releases" and route[1] in releases:
    rid = route[1]
    if method == "GET":
        code, body = 200, releases[rid]
    elif method == "PATCH":
        req = json.loads(data)
        releases[rid].update(req)
        if not releases[rid]["draft"]:
            tags[releases[rid]["tag_name"]] = os.environ.get("FAKE_TAG_SHA", req["target_commitish"])
        code, body = 200, releases[rid]
    elif method == "DELETE":
        del releases[rid]
        code, body = 204, b""
elif len(route) == 3 and route[0] == "releases" and route[2] == "assets" and method == "POST":
    name, _, src = form.partition("=@")
    aid = "a" + route[1]
    os.makedirs(os.path.join(forge, "assets"), exist_ok=True)
    open(os.path.join(forge, "assets", aid), "wb").write(open(src, "rb").read())
    releases[route[1]]["asset"] = re.sub(r".*[?&]name=", "", path)
    code, body = 201, {"id": 3}
elif route[:2] == ["releases", route[1]] and route[2:4] == ["assets", "3"] and method == "GET":
    url_ = os.environ.get("FAKE_ASSET_URL", server + "/attachments/a" + route[1])
    code, body = 200, {"id": 3, "browser_download_url": url_}
save("releases.json", releases)
save("tags.json", tags)
if lose:
    sys.exit(52)
reply(code, body)
