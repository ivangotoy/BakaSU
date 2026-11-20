#!/usr/bin/env bash
# Offline tests for .forgejo/manager-ci.sh and .forgejo/apk-cert.py: no network, no root, no
# Android SDK. Runs the real script modes against fixture git repositories, a fake forge
# (fake-curl.py) and stub build tools, all inside a temp dir created here.
#
#   run.sh [tree]   tree whose .forgejo/ scripts are tested (default: this repository)
# Checks are shell conditions in single quotes, evaluated by check(): variables are expanded
# there and set for it (SC2016, SC2034 do not apply).
# shellcheck disable=SC2016,SC2034
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(cd "${1:-$HERE/../..}" && pwd)"
CI="$TREE/.forgejo/manager-ci.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
REAL_GIT="$(command -v git)"
REAL_PY="$(command -v python3)"
SERVER=https://forge.example.com
REPOSITORY=owner/BakaSU
TOKEN="$(printf 'fixture-token-%s' 41)"
STORE_PW="$(printf 'fixture store %s' "pw'1")"
KEY_PW="$(printf 'fixture-key-%s' 2)"
npass=0 nfail=0
# check <name> <shell condition>: the condition is evaluated in this shell (functions visible)
check() {
    if eval "$2"; then echo "ok   $1"; npass=$((npass + 1)); else echo "FAIL $1"; nfail=$((nfail + 1)); fi
}
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }

# isolation: no host git identity, credential helper or system config
unset ANDROID_SDK_ROOT ANDROID_NDK_HOME ANDROID_NDK GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT
export HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$W/gitconfig" LANG=C.UTF-8
mkdir -p "$HOME" "$W/bin" "$W/logs"
cat > "$GIT_CONFIG_GLOBAL" <<EOF
[user]
	name = Fixture
	email = fixture@example.com
[init]
	defaultBranch = main
[protocol "file"]
	allow = always
[url "file://$W/upstream.git"]
	insteadOf = https://github.com/Baka-SU/BakaSU.git
[url "file://$W/origin.git"]
	insteadOf = $SERVER/$REPOSITORY.git
EOF

# stubs: argv of every stubbed or wrapped command is logged to $W/logs/argv
for t in git python3; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >> "%s/logs/argv"\nexec "%s" "$@"\n' \
        "$t" "$W" "$([ "$t" = git ] && echo "$REAL_GIT" || echo "$REAL_PY")" > "$W/bin/$t"
done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "curl $*" >> "%s/logs/argv"\nexec "%s" -I "%s/fake-curl.py" "$@"\n' \
    "$W" "$REAL_PY" "$HERE" > "$W/bin/curl"
# root-only tools of build mode: chown is logged only; setpriv runs the command without
# changing ids, except kill (the host uid may be the build uid: never kill -9 -1 here)
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "chown $*" >> "%s/logs/argv"\n' "$W" > "$W/bin/chown"
cat > "$W/bin/setpriv" <<EOF
#!/usr/bin/env bash
printf '%s\n' "setpriv \$*" >> "$W/logs/argv"
while [ "\${1#--}" != "\$1" ]; do shift; done
[ "\$1" = kill ] && exit 0
exec "\$@"
EOF
# cargo / rustup: ksud "build" writes a file and records its environment
cat > "$W/bin/cargo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "cargo \$*" >> "$W/logs/argv"
env > "$W/logs/cargo-env"
mkdir -p target/aarch64-linux-android/release && printf 'ksud' > target/aarch64-linux-android/release/ksud
EOF
mkdir -p "$W/rust/cargo/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "rustup $*" >> "%s/logs/argv"\n' "$W" > "$W/rust/cargo/bin/rustup"
# Android SDK: two build-tools versions (version sort must pick 36.0.0), NDK with a no-op strip
SDK="$W/sdk" BT="$W/sdk/build-tools/36.0.0"
mkdir -p "$BT" "$SDK/build-tools/9.0.0" "$SDK/ndk/29.0.14206865/toolchains/llvm/prebuilt/linux-x86_64/bin"
printf '#!/bin/sh\nexit 0\n' > "$SDK/ndk/29.0.14206865/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
for t in aapt2 apksigner zipalign; do printf '#!/bin/sh\necho "wrong build-tools" >&2; exit 1\n' > "$SDK/build-tools/9.0.0/$t"; done
cat > "$BT/aapt2" <<'EOF'
#!/bin/sh
echo "package: name='com.example.manager' versionCode='35271' versionName='${FAKE_VERSION_NAME:-v4.2.0-rc3-ci5}' platformBuildVersionName='17'"
EOF
printf '#!/bin/sh\n[ "$1 $2 $3 $4" = "-P 16 -f 4" ] && cp "$5" "$6"\n' > "$BT/zipalign"
# apksigner sign: resolves --ks-pass/--key-pass (pass:/env:), refuses wrong values, copies in->out
cat > "$BT/apksigner" <<EOF
#!/usr/bin/env bash
printf '%s\n' "apksigner \$*" >> "$W/logs/argv"
[ "\$1" = verify ] && exit 0
pw() { case "\$1" in pass:*) printf '%s' "\${1#pass:}" ;; env:*) n="\${1#env:}"; printf '%s' "\${!n-}" ;; *) printf 'unsupported' ;; esac; }
out="" ks="" kp="" a=""
while [ \$# -gt 1 ]; do
    case "\$1" in --ks-pass) ks="\$(pw "\$2")"; shift ;; --key-pass) kp="\$(pw "\$2")"; shift ;; --out) out="\$2"; shift ;; esac
    shift
done
[ "\$ks" = "\$FIXTURE_STORE_PW" ] && [ "\$kp" = "\$FIXTURE_KEY_PW" ] || { echo "apksigner stub: wrong password" >&2; exit 1; }
cp "\$1" "\$out"
EOF
for t in aapt2 apksigner zipalign; do ln -s "$BT/$t" "$W/bin/$t"; done
printf '#!/bin/sh\nexec tr -d "\\r"\n' > "$W/bin/dos2unix"
chmod +x "$W"/bin/* "$W/rust/cargo/bin/rustup" "$BT"/* "$SDK"/build-tools/9.0.0/* "$SDK"/ndk/*/toolchains/llvm/prebuilt/*/bin/*
export PATH="$W/bin:$PATH" FAKE_FORGE="$W/forge" FAKE_SERVER_URL="$SERVER" FAKE_TOKEN="$TOKEN" \
    FIXTURE_STORE_PW="$STORE_PW" FIXTURE_KEY_PW="$KEY_PW"
mkapk() { python3 -I "$HERE/make-apk.py" "$@"; }

apkcert() { python3 -I "$TREE/.forgejo/apk-cert.py" "$1" 2>/dev/null; }
echo "--- apk-cert.py"
mkapk "$W/c735.apk" 735 v2 > "$W/c735.want"
check "apk-cert: size and sha256 of the first v2 certificate" '[ "$(apkcert "$W/c735.apk")" = "$(cat "$W/c735.want")" ]'
mkapk "$W/c1025.apk" 1025 v2 > "$W/c1025.want"
check "apk-cert: 1025-byte certificate is reported as 1025" '[ "$(apkcert "$W/c1025.apk")" = "$(cat "$W/c1025.want")" ]'
mkapk "$W/none.apk" 735 none
check "apk-cert: no signing block fails" '! apkcert "$W/none.apk" >/dev/null'
mkapk "$W/v3.apk" 735 v3 > /dev/null
check "apk-cert: v3-only block fails" '! apkcert "$W/v3.apk" >/dev/null'

# fixture repositories: upstream U0 <- U1 (tag v4.2.0-rc3 on U0); fork main B = U0 + fork files
git init -q --bare "$W/upstream.git"; git init -q --bare "$W/origin.git"
git init -q "$W/u"
(   cd "$W/u" && echo upstream > README && git add README && git commit -q -m U0 && git tag v4.2.0-rc3 \
    && git push -q "$W/upstream.git" main --tags \
    && echo change >> README && git commit -q -am U1 && git push -q "$W/upstream.git" main ) || exit 1
git clone -q "$W/upstream.git" "$W/f"
(   cd "$W/f" && git reset -q --hard HEAD~1 \
    && mkdir -p .forgejo .github/scripts manager userspace/ksud && touch userspace/ksud/.keep \
    && cp "$CI" "$TREE/.forgejo/apk-cert.py" .forgejo/ && cp "$TREE/.github/scripts/setup-rust-build.sh" .github/scripts/ \
    && cp "$TREE/repack_apk.py" "$TREE/repack_apk_multi.py" . \
    && { [ ! -f "$TREE/.forgejo/repack-sign.py" ] || cp "$TREE/.forgejo/repack-sign.py" .forgejo/; } \
    && cat > manager/gradlew <<EOF
#!/usr/bin/env bash
printf '%s\n' "gradlew \$*" >> "$W/logs/argv"
env > "$W/logs/gradle-env"
d=app/build/outputs/apk/release; mkdir -p "\$d"
python3 -I "$HERE/make-apk.py" "\$d/BakaSU_v4.2.0-rc3_35271-arm64-v8a-release.apk" 735 v2 lib/arm64-v8a/libkernelsu.so >/dev/null
python3 -I "$HERE/make-apk.py" "\$d/BakaSU_v4.2.0-rc3_35271-x86_64-release.apk" 735 v2 lib/x86_64/libkernelsu.so >/dev/null
EOF
    git add -A && git commit -q -m B && git push -q "$W/origin.git" HEAD:refs/heads/main ) || exit 1
B="$(git -C "$W/f" rev-parse HEAD)"; U0="$(git -C "$W/u" rev-parse HEAD~1)"; U1="$(git -C "$W/u" rev-parse HEAD)"
cp -a "$W/origin.git" "$W/origin.pristine"
fresh_origin() { rm -rf "$W/origin.git"; cp -a "$W/origin.pristine" "$W/origin.git"; }

echo "--- build mode: environment handed to the build user"
git clone -q "$W/origin.git" "$W/b1"
printf '#!/usr/bin/env bash\ncat /proc/$$/environ > "%s/logs/build-env"\n' "$W" > "$W/b1/.forgejo/manager-ci.sh"
: > "$W/logs/argv"
env "odd-name=1" CANARY_TOKEN="$(printf 'canary-%s' 7)" BASE_SHA="$B" SIGN_KEYSTORE_B64=a SIGN_KEY_ALIAS=b \
    SIGN_STORE_PASSWORD="$STORE_PW" SIGN_KEY_PASSWORD="$KEY_PW" bash "$CI" build "$W/b1" > "$W/logs/b1" 2>&1
b1=$?
names="$(tr '\0' '\n' < "$W/logs/build-env" 2>/dev/null | cut -d= -f1 | sort | tr '\n' ' ')"
allowed=" ANDROID_HOME ANDROID_SDK_ROOT BASE_SHA GIT_HTTP_LOW_SPEED_LIMIT GIT_HTTP_LOW_SPEED_TIME GRADLE_USER_HOME HOME JAVA_HOME LANG OLDPWD PATH PWD SHLVL SIGN_KEYSTORE_B64 SIGN_KEY_ALIAS SIGN_KEY_PASSWORD SIGN_STORE_PASSWORD _ "
only_allowed() { local n; for n in $names; do case "$allowed" in *" $n "*) ;; *) echo "unexpected variable $n"; return 1 ;; esac; done; }
check "build: exits 0" '[ "$b1" = 0 ]'
check "build: only the allowed variables reach build-user (canary dropped)" 'only_allowed && [ -n "$names" ]'
all_present() { local n; for n in "$@"; do case " $names" in *" $n "*) ;; *) return 1 ;; esac; done; }
check "build: signing settings and BASE_SHA reach build-user" \
    'all_present SIGN_KEYSTORE_B64 SIGN_KEY_ALIAS SIGN_STORE_PASSWORD SIGN_KEY_PASSWORD BASE_SHA'
check "build: non-identifier variable dropped" 'case "$names" in *odd-name*) false ;; esac'
check "build: HOME is the workspace .ci-home" 'tr "\0" "\n" < "$W/logs/build-env" | grep -qx "HOME=$W/b1/.ci-home"'
check "build: build-user runs as uid 1000, its processes are killed after" \
    'grep -q -- "--reuid=1000 --regid=1000 --clear-groups bash" "$W/logs/argv" && grep -q -- "--reuid=1000 --regid=1000 --clear-groups kill -9 -1" "$W/logs/argv"'

buser() { # buser <workdir> [VAR=value ...]: build-user with fixture settings
    local d="$1"; shift
    ( cd "$W" && env BASE_SHA="$(git -C "$d" rev-parse HEAD)" SIGN_KEYSTORE_B64="$(printf 'keystore' | base64)" \
        SIGN_KEY_ALIAS=fixture SIGN_STORE_PASSWORD="$STORE_PW" SIGN_KEY_PASSWORD="$KEY_PW" CI_RUST_HOME="$W/rust" \
        ANDROID_HOME="$SDK" GRADLE_USER_HOME="$W/gradle" "$@" bash "$CI" build-user "$d" )
}
echo "--- build-user mode (upstream ahead: merge)"
git clone -q "$W/origin.git" "$W/b2"
git -C "$W/b2" tag v4.2.0-rc3-ci4
: > "$W/logs/argv"
buser "$W/b2" > "$W/logs/b2" 2>&1
b2=$?
O="$W/b2/.ci-out"
M2="$(sed -n 1p "$O/src" 2>/dev/null)"
check "build-user: exits 0" '[ "$b2" = 0 ]'
check "build-user: manager.apk written" '[ -f "$O/manager.apk" ]'
check "build-user: src = merge of BASE and upstream" '[ "$(git -C "$W/b2" rev-parse "$M2^1" "$M2^2" 2>/dev/null | tr "\n" " ")" = "$B $U1 " ]'
check "build-user: src line 2 = upstream sha" '[ "$(sed -n 2p "$O/src" 2>/dev/null)" = "$U1" ]'
check "build-user: merge.bundle holds the merge as main" \
    'git -C "$W/b2" bundle list-heads "$O/merge.bundle" 2>/dev/null | grep -qx "$M2 refs/heads/main"'
check "build-user: fork -ciN tags dropped, upstream tags kept" '[ "$(git -C "$W/b2" tag -l | tr "\n" " ")" = "v4.2.0-rc3 " ]'
check "build-user: only the arm64-v8a APK is repacked" \
    '[ "$(find "$W/b2/manager/app/build/outputs/apk/release" -name "*.apk" | wc -l)" = 1 ]'
check "build-user: signing key file removed" '[ ! -e "$HOME/fork-key.p12" ]'
check "build-user: apksigner sign ran (stub checks the passwords)" 'grep -q "^apksigner sign" "$W/logs/argv"'
check "build-user: signing passwords never in argv" '! grep -qF -e "$STORE_PW" -e "$KEY_PW" "$W/logs/argv"'
check "build-user: signing secrets not in the Gradle environment" '[ -f "$W/logs/gradle-env" ] && ! grep -q "^SIGN_" "$W/logs/gradle-env"'
check "build-user: signing secrets not in the cargo environment" '[ -f "$W/logs/cargo-env" ] && ! grep -q "^SIGN_" "$W/logs/cargo-env"'

echo "--- build-user mode (upstream already merged; failures)"
git clone -q "$W/origin.git" "$W/b3"
( cd "$W/b3" && git fetch -q "$W/upstream.git" main && git merge -q --no-edit FETCH_HEAD ) > /dev/null 2>&1
B3="$(git -C "$W/b3" rev-parse HEAD)"
buser "$W/b3" > "$W/logs/b3" 2>&1
b3=$?
check "build-user (merged): exits 0, src = BASE, no bundle" \
    '[ "$b3" = 0 ] && [ "$(sed -n 1p "$W/b3/.ci-out/src")" = "$B3" ] && [ ! -e "$W/b3/.ci-out/merge.bundle" ]'
buser "$W/b3" SIGN_KEY_PASSWORD="$(true)" > "$W/logs/b3-nosign" 2>&1
b3n=$?
check "build-user: missing signing setting refused by name" '[ "$b3n" != 0 ] && grep -q "SIGN_KEY_PASSWORD is not set" "$W/logs/b3-nosign"'
buser "$W/b3" FIXTURE_STORE_PW=other > "$W/logs/b3-badpw" 2>&1
b3p=$?
check "build-user: signing failure fails the build, passwords not logged" \
    '[ "$b3p" != 0 ] && grep -q "apksigner failed" "$W/logs/b3-badpw" && ! grep -qF -e "$STORE_PW" -e "$KEY_PW" "$W/logs/b3-badpw"'
python3 -I -c 'import json,os,sys;json.dump({"signing":{"keystore_pass":os.environ["FIXTURE_STORE_PW"],"key_pass":os.environ["FIXTURE_KEY_PW"]}},open(sys.argv[1],"w"))' \
    "$W/b3/repack-config.json"
buser "$W/b3" > "$W/logs/b3-config" 2>&1
b3c=$?
rm -f "$W/b3/repack-config.json"
check "build-user: signing refused when apksigner would not get env: password references" \
    '[ "$b3c" != 0 ] && grep -q "did not get both passwords as env: references" "$W/logs/b3-config"'

# release fixtures: a merge M of B and U1 (and broken variants) as bundles of B..main
git clone -q "$W/origin.git" "$W/m"
git -C "$W/m" fetch -q "$W/upstream.git" main
mk_merge() { # mk_merge <name> <parent>...: prints the merge sha, writes $W/<name>.bundle
    local n="$1" tree p args=(); shift
    tree="$(git -C "$W/m" merge-tree --write-tree "$B" "$U1")" || return 1
    [ "$n" != badtree ] || tree="$(git -C "$W/m" rev-parse "$B^{tree}")"
    for p in "$@"; do args+=(-p "$p"); done
    c="$(git -C "$W/m" commit-tree "$tree" "${args[@]}" -m "merge $n")" || return 1
    git -C "$W/m" branch -q -f "x-$n" "$c" && git -C "$W/m" update-ref refs/heads/main "$c" 2>/dev/null \
        || git -C "$W/m" checkout -q --detach && git -C "$W/m" update-ref refs/heads/main "$c"
    git -C "$W/m" bundle create -q "$W/$n.bundle" "$B..main" 2>/dev/null && echo "$c"
}
git -C "$W/m" checkout -q --detach
X="$(git -C "$W/m" commit-tree "$(git -C "$W/m" rev-parse "$U0^{tree}")" -p "$U0" -m extra)"
M="$(mk_merge good "$B" "$U1")"; MSWAP="$(mk_merge swapped "$U1" "$B")"
MOCT="$(mk_merge octopus "$B" "$U1" "$X")"; MTREE="$(mk_merge badtree "$B" "$U1")"
mkapk "$W/a735.apk" 735 v2 > "$W/a735.want"; mkapk "$W/a1024.apk" 1024 v2 > /dev/null; mkapk "$W/a1025.apk" 1025 v2 > /dev/null

# rcase <name> <src-sha> <up-sha> <apk> <bundle|-> [VAR=value ...]: one release run on a fresh forge
# and origin; PREP (environment) is evaluated in the case dir before the run
rcase() {
    local n="$1" src="$2" up="$3" apk="$4" bundle="$5"; shift 5
    local d="$W/r/$n"
    mkdir -p "$d/src/.ci-out"; rm -rf "$W/forge"; mkdir -p "$W/forge"; fresh_origin
    printf '%s\n%s\n' "$src" "$up" > "$d/src/.ci-out/src"
    cp "$apk" "$d/src/.ci-out/manager.apk"
    [ "$bundle" = - ] || cp "$bundle" "$d/src/.ci-out/merge.bundle"
    [ -z "${PREP:-}" ] || ( cd "$d" && eval "$PREP" )
    : > "$W/logs/argv"
    ( cd "$d" && env RELEASE_TOKEN="$TOKEN" RUN_NUMBER=9 SERVER_URL="$SERVER" REPOSITORY="$REPOSITORY" BASE_SHA="$B" \
        ANDROID_HOME="$SDK" "$@" bash "$CI" release src ) > "$d/log" 2>&1
    echo $? > "$d/rc"
    cp "$W/logs/argv" "$d/argv"
    git -C "$W/origin.git" rev-parse main > "$d/main"
}
ok() { [ "$(cat "$W/r/$1/rc")" = 0 ]; }
failed() { [ "$(cat "$W/r/$1/rc")" != 0 ]; }
said() { grep -qF -- "$2" "$W/r/$1/log"; }
main_is() { [ "$(cat "$W/r/$1/main")" = "$2" ]; }
nrel() { python3 -I -c 'import json,sys,os;p=sys.argv[1]+"/releases.json";print(len(json.load(open(p))) if os.path.exists(p) else 0)' "$W/forge"; }
rel() { python3 -I -c 'import json,sys;r=list(json.load(open(sys.argv[1]+"/releases.json")).values())[0];print(r.get(sys.argv[2]))' "$W/forge" "$1"; }
tagsha() { python3 -I -c 'import json,sys,os;p=sys.argv[1]+"/tags.json";print(json.load(open(p)).get(sys.argv[2],"") if os.path.exists(p) else "")' "$W/forge" "$1"; }
notoken() { ! grep -qF -- "$TOKEN" "$W/r/$1/argv" "$W/r/$1/log"; }

echo "--- release mode"
rcase ok-merge "$M" "$U1" "$W/a735.apk" "$W/good.bundle"
check "release: merge build publishes" 'ok ok-merge'
check "release: tag = versionName without -ciN + -ci<run>, at the merge" '[ "$(tagsha v4.2.0-rc3-ci9)" = "$M" ]'
check "release: published (not draft) with the APK asset" \
    '[ "$(rel draft)" = False ] && [ "$(rel asset)" = BakaSU-v4.2.0-rc3-ci9-arm64-v8a.apk ]'
check "release: merge pushed to main" 'main_is ok-merge "$M"'
read -r csize csha < "$W/a735.want"
check "release: body carries the kernel signature size and hash" 'rel body | grep -qF "size $csize (0x2df) hash $csha"'
check "release: curl reads the token from a header file" 'grep -q "^curl .* -H @" "$W/r/ok-merge/argv"'
check "release: reads are retried, writes are not" \
    'grep -q "^curl .* --retry 3 -X GET " "$W/r/ok-merge/argv" && ! grep -qE "^curl .* --retry .* -X (POST|PATCH|DELETE) " "$W/r/ok-merge/argv"'

rcase ok-nomerge "$B" "$U0" "$W/a1024.apk" - FAKE_VERSION_NAME='v4.2.0 beta/x'
check "release: no-merge build publishes at BASE; 1024-byte cert accepted" 'ok ok-nomerge && main_is ok-nomerge "$B"'
check "release: tag characters outside [A-Za-z0-9._-] become -" '[ "$(tagsha v4.2.0-beta-x-ci9)" = "$B" ]'

rcase cert-big "$B" "$U0" "$W/a1025.apk" -
check "release: certificate > 1024 bytes refused before any release" \
    'failed cert-big && said cert-big "the kernel accepts at most 1024" && [ "$(nrel)" = 0 ]'
PREP='printf "{\"v4.2.0-rc3-ci9\": \"%s\"}" "$B" > "$FAKE_FORGE/tags.json"' rcase tag-exists "$B" "$U0" "$W/a735.apk" -
check "release: existing tag refused" 'failed tag-exists && said tag-exists "tag v4.2.0-rc3-ci9 exists" && [ "$(nrel)" = 0 ]'
PREP='printf "{\"7\": {\"id\": 7, \"tag_name\": \"v4.2.0-rc3-ci9\", \"draft\": false}}" > "$FAKE_FORGE/releases.json"' \
    rcase rel-exists "$B" "$U0" "$W/a735.apk" -
check "release: existing release refused" 'failed rel-exists && said rel-exists "release v4.2.0-rc3-ci9 exists"'
rcase bad-src "not-a-sha" "$U0" "$W/a735.apk" -
check "release: bad source sha refused" 'failed bad-src && said bad-src "bad source sha"'
rcase bad-up "$B" "${U0:0:39}" "$W/a735.apk" -
check "release: bad upstream sha refused" 'failed bad-up && said bad-up "bad upstream sha"'
rcase up-foreign "$B" "$X" "$W/a735.apk" -
check "release: upstream sha not on upstream main refused" 'failed up-foreign && said up-foreign "is not on upstream main"'
PREP='rm src/.ci-out/manager.apk && ln -s "$W/a735.apk" src/.ci-out/manager.apk' rcase apk-link "$B" "$U0" "$W/a735.apk" -
check "release: symlinked manager.apk refused" 'failed apk-link && said apk-link "manager.apk is not a regular file"'
PREP='rm src/.ci-out/src && mkfifo src/.ci-out/src' rcase src-fifo "$B" "$U0" "$W/a735.apk" -
check "release: non-regular src refused" 'failed src-fifo && said src-fifo "src is not a regular file"'
PREP='mv src/.ci-out real-out && ln -s ../real-out src/.ci-out' rcase out-link "$B" "$U0" "$W/a735.apk" -
check "release: symlinked .ci-out refused" 'failed out-link && said out-link ".ci-out is not a directory" && [ "$(nrel)" = 0 ]'
rcase no-bundle "$M" "$U1" "$W/a735.apk" -
check "release: merge without bundle refused" 'failed no-bundle && said no-bundle "merge.bundle is not a regular file"'
rcase bundle-tip "$M" "$U1" "$W/a735.apk" "$W/swapped.bundle"
check "release: bundle tip other than the built sha refused" 'failed bundle-tip && said bundle-tip "bundle tip differs"'
rcase swapped "$MSWAP" "$U1" "$W/a735.apk" "$W/swapped.bundle"
check "release: merge with swapped parents refused" 'failed swapped && said swapped "merge parents differ" && main_is swapped "$B"'
rcase badtree "$MTREE" "$U1" "$W/a735.apk" "$W/badtree.bundle"
check "release: merge with another tree refused" 'failed badtree && said badtree "merge tree differs" && main_is badtree "$B"'
rcase octopus "$MOCT" "$U1" "$W/a735.apk" "$W/octopus.bundle"
check "release: merge with a third parent refused, main unchanged" \
    'failed octopus && said octopus "merge parents differ" && main_is octopus "$B" && [ "$(nrel)" = 0 ]'
rcase corrupt "$M" "$U1" "$W/a735.apk" "$W/good.bundle" FAKE_CORRUPT_DOWNLOAD=1
check "release: download-back mismatch deletes the draft, main unchanged" \
    'failed corrupt && said corrupt "deleting draft release" && [ "$(nrel)" = 0 ] && main_is corrupt "$B"'
rcase lost-publish "$B" "$U0" "$W/a735.apk" - FAKE_LOSE_REPLY="PATCH /releases/7"
check "release: publish applied but reply lost keeps the release" \
    'failed lost-publish && said lost-publish "not deleted (draft state '"'False'"')" && [ "$(nrel)" = 1 ] && [ "$(rel draft)" = False ]'
rcase upload-fail "$B" "$U0" "$W/a735.apk" - FAKE_FAIL="POST /assets"
check "release: failed upload deletes the draft" 'failed upload-fail && said upload-fail "deleting draft release" && [ "$(nrel)" = 0 ]'
rcase tag-moved "$B" "$U0" "$W/a735.apk" - FAKE_TAG_SHA="$U0"
check "release: published tag at another commit fails" 'failed tag-moved && said tag-moved "points at"'
rcase foreign-asset "$B" "$U0" "$W/a735.apk" - FAKE_ASSET_URL=https://other.example.net/attachments/a7
check "release: asset URL outside the forge refused, token header never sent there" \
    'failed foreign-asset && ! grep -q "other.example.net" "$W/r/foreign-asset/argv" && [ "$(nrel)" = 0 ]'
rcase repo-asset "$B" "$U0" "$W/a735.apk" - FAKE_ASSET_URL="$SERVER/owner/BakaSU/releases/download/v4.2.0-rc3-ci9/a7"
check "release: asset URL in the repository download path of the forge accepted" 'ok repo-asset && said repo-asset "downloading back $SERVER/owner/"'
for n in "$W"/r/*/; do n="$(basename "$n")"; check "release ($n): token never in argv or log" "notoken $n"; done

echo "--- ksud installer.sh: module id of install_module"
INST="$TREE/userspace/ksud/src/android/module/installer.sh"
modid() { # modid <module.prop text> [KSU_MODULE]: MODID as install_module sets it
    mkdir -p "$W/inst" && printf '%s\n' "$1" > "$W/inst/module.prop"
    (   TMPDIR="$W/inst"; unset KSU_MODULE; [ $# -lt 2 ] || KSU_MODULE="$2"
        eval "$(sed -n '/^grep_prop() {/,/^}/p' "$INST")"
        eval "$(grep -m1 '^  MODID=' "$INST")"
        printf '%s' "$MODID" )
}
check "installer: MODID is the validated id when another value contains id= first" \
    '[ "$(modid "$(printf "updateJson=https://example.com/u.json?id=other\nid=good")" good)" = good ]'
check "installer: MODID is the validated id for a spaced key (id = x)" '[ "$(modid "id = spaced" spaced)" = spaced ]'
check "installer: MODID from module.prop without KSU_MODULE" '[ "$(modid "$(printf "name=x\nid=plain")")" = plain ]'

echo
echo "forgejo tests: $npass passed, $nfail failed"
[ "$nfail" = 0 ]
