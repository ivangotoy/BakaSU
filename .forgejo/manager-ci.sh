#!/usr/bin/env bash
# BakaSU fork: manager APK release pipeline (workflow: .forgejo/workflows/manager-release.yml).
#
#   manager-ci.sh build <workdir>       root in the job container: hands the tree to an
#                                       unprivileged user with a scrubbed environment and runs
#                                       build-user as that user
#   manager-ci.sh build-user <workdir>  unprivileged: merge upstream main, build ksud (arm64),
#                                       build the release APK with Gradle, repack it with ksud and
#                                       sign it with the fork key -> $OUT/manager.apk
#   manager-ci.sh release <workdir>     forge token: draft release -> upload -> download back and
#                                       compare sha256 -> push the merge to main -> publish
#
# Only arm64-v8a is built and released (ksud for one target, no LKM, no ksuinit: for kernels
# with KernelSU built in). The release step runs this script as fetched from the dispatched
# commit, never the copy in the build workspace. A failure before publish deletes the draft.
set -euo pipefail
export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1024}" GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-60}"

MODE="${1:?mode}"; WORK="$(cd "${2:?workdir}" && pwd)"
UPSTREAM_URL=https://github.com/Baka-SU/BakaSU.git
UPSTREAM_BRANCH=main
RUSTUP_VERSION=1.29.3
RUST_TOOLCHAIN=nightly-2026-11-15
KSUD_TARGET=aarch64-linux-android
ABI=arm64-v8a
NDK_VERSION=29.0.14206865
BUILD_UID=1000
OUT="$WORK/.ci-out"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
jget() { python3 -I -c 'import json,sys;d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[int(k)] if k.isdigit() else d[k]
print(d)' "$1"; }
build_tool() { printf '%s\n' "${ANDROID_HOME:-/opt/android-sdk}"/build-tools/*/"$1" | sort -V | tail -n1; }

if [ "$MODE" = build-user ]; then
    cd "$WORK"
    for v in SIGN_KEYSTORE_B64 SIGN_KEY_ALIAS SIGN_STORE_PASSWORD SIGN_KEY_PASSWORD; do
        [ -n "${!v:-}" ] || die "$v is not set"
    done
    # shell variables from here on: cargo, Gradle and their build scripts do not inherit them;
    # only the sign step gets the passwords, in its own environment
    export -n SIGN_KEYSTORE_B64 SIGN_KEY_ALIAS SIGN_STORE_PASSWORD SIGN_KEY_PASSWORD
    BASE_SHA="${BASE_SHA:-$(git rev-parse HEAD)}"
    rm -rf "$OUT"; mkdir -p "$OUT"
    printf '.ci-out/\n.ci-home/\n/target/\n/dist/\n' >> .git/info/exclude
    git checkout -q -B main "$BASE_SHA"
    # the upstream merge carries the identity the release is configured with (build mode requires
    # it); a direct build-user run without one gets a neutral identity, never one of a commit
    GIT_AUTHOR_NAME="${MERGE_AUTHOR_NAME:-manager-ci}" GIT_AUTHOR_EMAIL="${MERGE_AUTHOR_EMAIL:-manager-ci@localhost}"
    export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

    # upstream main and upstream's tags (versionName is `git describe --tags`; the clone has no
    # fork tags, so a fork release tag never becomes the next versionName)
    log "merging $UPSTREAM_URL $UPSTREAM_BRANCH"
    git fetch -q --no-tags "$UPSTREAM_URL" "+refs/heads/$UPSTREAM_BRANCH:refs/ci/upstream" "+refs/tags/*:refs/tags/*"
    UP_SHA="$(git rev-parse refs/ci/upstream)"
    # fork release tags (<version>-ciN) must never become the next versionName
    git tag -l '*-ci[0-9]*' | xargs -r git tag -d >/dev/null
    if git merge-base --is-ancestor "$UP_SHA" HEAD; then
        log "upstream $UP_SHA already merged"
    else
        git merge -q --no-ff --no-edit -m "Merge Baka-SU/BakaSU $UPSTREAM_BRANCH ${UP_SHA:0:12}" "$UP_SHA" \
            || die "merge conflict with upstream $UP_SHA: resolve by hand"
    fi
    SRC_SHA="$(git rev-parse HEAD)"
    [ "$SRC_SHA" = "$BASE_SHA" ] || git bundle create -q "$OUT/merge.bundle" "$BASE_SHA..main"
    printf '%s\n%s\n' "$SRC_SHA" "$UP_SHA" > "$OUT/src"

    # Rust: pinned rustup + nightly in a mounted cache dir, never in the image
    RUST_HOME="${CI_RUST_HOME:-/ci/gradle/rust}"
    export RUSTUP_HOME="$RUST_HOME/rustup" CARGO_HOME="$RUST_HOME/cargo"
    export PATH="$CARGO_HOME/bin:$PATH"
    if ! "$CARGO_HOME/bin/rustup" --version >/dev/null 2>&1; then
        log "installing rustup $RUSTUP_VERSION into $RUST_HOME"
        mkdir -p "$RUST_HOME"
        curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 30 --max-time 600 -o "$RUST_HOME/rustup-init" \
            "https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/x86_64-unknown-linux-gnu/rustup-init"
        chmod +x "$RUST_HOME/rustup-init"
        "$RUST_HOME/rustup-init" -y -q --no-modify-path --profile minimal --default-toolchain none
        rm -f "$RUST_HOME/rustup-init"
    fi
    rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal >&2
    rustup target add --toolchain "$RUST_TOOLCHAIN" "$KSUD_TARGET" >&2

    # ksud (upstream .github/workflows/ksud.yml, without cargo-ndk: same NDK clang env)
    export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$NDK_VERSION"
    [ -d "$ANDROID_NDK_HOME" ] || die "NDK $NDK_VERSION not in $ANDROID_HOME/ndk"
    export LIBCLANG_PATH="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib"
    # shellcheck source=/dev/null
    . .github/scripts/setup-rust-build.sh "$KSUD_TARGET" 26
    log "building ksud for $KSUD_TARGET with $RUST_TOOLCHAIN"
    (cd userspace/ksud && cargo "+$RUST_TOOLCHAIN" build --locked --release --target "$KSUD_TARGET" -Z trim-paths >&2)
    mkdir -p "target/$KSUD_TARGET/release"
    cp -f "userspace/ksud/target/$KSUD_TARGET/release/ksud" "target/$KSUD_TARGET/release/ksud"

    # manager APK (upstream build-manager.yml build-manager job)
    export GRADLE_USER_HOME="${GRADLE_USER_HOME:-/ci/gradle}"
    log "building the manager APK"
    (cd manager && chmod +x gradlew && ./gradlew --no-daemon assembleRelease -Pcommit="$SRC_SHA" >&2)
    d=manager/app/build/outputs/apk/release
    mapfile -t apks < <(find "$d" -maxdepth 1 -name "*-$ABI-release*.apk")
    [ "${#apks[@]}" = 1 ] || die "expected one $ABI release APK in $d, found ${#apks[@]}"
    find "$d" -maxdepth 1 -name '*.apk' ! -path "${apks[0]}" -delete

    # repack with ksud and sign (upstream build-manager.yml repack-manager job)
    KEY="$HOME/fork-key.p12"
    trap 'rm -f "$KEY"' EXIT
    (umask 077; printf '%s' "$SIGN_KEYSTORE_B64" | base64 -d > "$KEY")
    rm -rf dist
    # upstream repack_apk_multi.py, with apksigner reading the passwords from its environment
    SIGN_STORE_PASSWORD="$SIGN_STORE_PASSWORD" SIGN_KEY_PASSWORD="$SIGN_KEY_PASSWORD" \
        python3 -I .forgejo/repack-sign.py "$WORK" "$ABI" "$KEY" "$SIGN_KEY_ALIAS" >&2
    mapfile -t apks < <(find dist -maxdepth 1 -name '*.apk')
    [ "${#apks[@]}" = 1 ] || die "repack left ${#apks[@]} APKs in dist"
    "$(build_tool apksigner)" verify "${apks[0]}" || die "apksigner verify failed"
    mv "${apks[0]}" "$OUT/manager.apk"
    log "built $OUT/manager.apk sha256 $(sha "$OUT/manager.apk")"
    exit 0
fi

if [ "$MODE" = build ]; then
    : "${BASE_SHA:?}"
    # author and committer of the release-time upstream merge, from the repository's Actions
    # variables: no fallback, the release stops when they are missing
    # a name of spaces only, or with a newline or other control character, is no identity
    name="${MERGE_AUTHOR_NAME:-}"
    [[ -n "${name//[[:space:]]/}" && ! "$name" =~ [[:cntrl:]] ]] \
        || die "MERGE_AUTHOR_NAME is not set or not a plain name"
    [[ "${MERGE_AUTHOR_EMAIL:-}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+$ ]] \
        || die "MERGE_AUTHOR_EMAIL is not set or not a plain e-mail address"
    export MERGE_AUTHOR_NAME MERGE_AUTHOR_EMAIL
    cd "$WORK"
    mkdir -p "$WORK/.ci-home"
    chown -R "$BUILD_UID:$BUILD_UID" "$WORK"
    log "building $BASE_SHA as uid $BUILD_UID"
    # The build user gets exactly the variables below (the signing secrets by environment, never
    # argv: apksigner reads the passwords as env: references, .forgejo/repack-sign.py):
    # un-export everything else, and let env(1) drop what bash cannot.
    (   keep=" PATH JAVA_HOME SIGN_KEYSTORE_B64 SIGN_KEY_ALIAS SIGN_STORE_PASSWORD SIGN_KEY_PASSWORD BASE_SHA MERGE_AUTHOR_NAME MERGE_AUTHOR_EMAIL GIT_HTTP_LOW_SPEED_LIMIT GIT_HTTP_LOW_SPEED_TIME "
        drop=()
        for v in $(compgen -e); do
            case "$keep" in *" $v "*) ;; *) export -n "${v?}" 2>/dev/null || drop+=(-u "$v") ;; esac
        done
        while IFS= read -r -d '' e; do
            [[ "${e%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || drop+=(-u "${e%%=*}")
        done < "/proc/$BASHPID/environ"
        export PATH HOME="$WORK/.ci-home" LANG=C.UTF-8 GRADLE_USER_HOME=/ci/gradle \
            JAVA_HOME="${JAVA_HOME:-}" ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk
        exec env ${drop[@]+"${drop[@]}"} setpriv --reuid="$BUILD_UID" --regid="$BUILD_UID" --clear-groups \
            bash "$WORK/.forgejo/manager-ci.sh" build-user "$WORK"
    ) || die "build failed"
    setpriv --reuid="$BUILD_UID" --regid="$BUILD_UID" --clear-groups kill -9 -1 2>/dev/null || true
    log "build done"
    exit 0
fi

[ "$MODE" = release ] || die "unknown mode $MODE"
: "${RELEASE_TOKEN:?}" "${RUN_NUMBER:?}" "${SERVER_URL:?}" "${REPOSITORY:?}" "${BASE_SHA:?}"
API="$SERVER_URL/api/v1/repos/$REPOSITORY"
# the token never goes into argv: curl reads the header from a 0600 file, git gets it through
# GIT_CONFIG_* environment variables
AUTH_DIR="$(mktemp -d)"
trap 'rm -rf "$AUTH_DIR"' EXIT
AUTH_H="$AUTH_DIR/header"
(umask 077; printf 'Authorization: token %s\n' "$RELEASE_TOKEN" > "$AUTH_H")
# only reads are retried: a retried POST/PATCH/DELETE can repeat a change the forge made
api() {
    local m="$1" p="$2" r=(); shift 2
    case "$m" in GET|HEAD) r=(--retry 3) ;; esac
    curl -sS --connect-timeout 30 --max-time 600 --fail-with-body ${r[@]+"${r[@]}"} -X "$m" -H "@$AUTH_H" "$@" "$API$p"
}
http_code() { curl -sS --connect-timeout 30 --max-time 600 -o /dev/null -w '%{http_code}' -H "@$AUTH_H" "$API$1"; }
git_auth() {
    (n="${GIT_CONFIG_COUNT:-0}"
     export GIT_CONFIG_COUNT=$((n + 1)) "GIT_CONFIG_KEY_$n=http.extraHeader" "GIT_CONFIG_VALUE_$n=Authorization: token $RELEASE_TOKEN"
     git "$@")
}

REL="$(pwd)/rel"
rm -rf "$REL"; mkdir -p "$REL"
git_auth clone -q --no-tags --branch main "$SERVER_URL/$REPOSITORY.git" "$REL/repo"
cd "$REL/repo"
git cat-file -e "$BASE_SHA^{commit}" || die "base $BASE_SHA not in main"
git merge-base --is-ancestor "$BASE_SHA" HEAD || die "base $BASE_SHA not in main"

# build results are data owned by the build user: regular files only, checked before use
regular() { [ -f "$1" ] && [ ! -L "$1" ] || die "$1 is not a regular file"; }
[ -d "$OUT" ] && [ ! -L "$OUT" ] || die "$OUT is not a directory"
regular "$OUT/src"; regular "$OUT/manager.apk"
{ read -r SRC_SHA; read -r UP_SHA; } < "$OUT/src"
[[ "$SRC_SHA" =~ ^[0-9a-f]{40}$ ]] || die "bad source sha"
[[ "$UP_SHA" =~ ^[0-9a-f]{40}$ ]] || die "bad upstream sha"
git fetch -q --no-tags "$UPSTREAM_URL" "$UPSTREAM_BRANCH"
git merge-base --is-ancestor "$UP_SHA" FETCH_HEAD || die "$UP_SHA is not on upstream $UPSTREAM_BRANCH"
if [ "$SRC_SHA" != "$BASE_SHA" ]; then
    regular "$OUT/merge.bundle"
    git fetch -q "$OUT/merge.bundle" "main:refs/ci/merge"
    [ "$(git rev-parse refs/ci/merge)" = "$SRC_SHA" ] || die "bundle tip differs from the built sha"
    # exactly two parents, in this order: a third parent would put foreign history on main
    [ "$(git rev-list --parents -n 1 "$SRC_SHA")" = "$SRC_SHA $BASE_SHA $UP_SHA" ] || die "merge parents differ"
    [ "$(git merge-tree --write-tree "$BASE_SHA" "$UP_SHA")" = "$(git rev-parse "$SRC_SHA^{tree}")" ] || die "merge tree differs"
fi
APK_SRC="$REL/manager.apk"
cp "$OUT/manager.apk" "$APK_SRC"

# version from the APK; signing certificate as the kernel reads it (first certificate of the
# first APK signature scheme v2 signer, kernel/manager/apk_sign.c): DER size and sha256
BADGING="$("$(build_tool aapt2)" dump badging "$APK_SRC" | sed -n 1p)"
VERSION_NAME="$(printf '%s' "$BADGING" | sed -n "s/.* versionName='\([^']*\)'.*/\1/p")"
VC="$(printf '%s' "$BADGING" | sed -n "s/.* versionCode='\([0-9]*\)'.*/\1/p")"
PKG="$(printf '%s' "$BADGING" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
[ -n "$VERSION_NAME" ] && [ -n "$VC" ] && [ -n "$PKG" ] || die "cannot read package/version from the APK"
git show "$BASE_SHA:.forgejo/apk-cert.py" > "$AUTH_DIR/apk-cert.py"
read -r CERT_SIZE CERT_SHA < <(python3 -I "$AUTH_DIR/apk-cert.py" "$APK_SRC")
[[ "$CERT_SHA" =~ ^[0-9a-f]{64}$ ]] || die "cannot read the APK signing certificate"
# kernel/manager/apk_sign.c rejects a signing certificate larger than CERT_MAX_LENGTH (1024)
[ "$CERT_SIZE" -le 1024 ] || die "signing certificate is $CERT_SIZE bytes; the kernel accepts at most 1024"
APK_SHA="$(sha "$APK_SRC")"
TAG="$(printf '%s-ci%s' "${VERSION_NAME%%-ci[0-9]*}" "$RUN_NUMBER" | sed -E 's/[^A-Za-z0-9._-]+/-/g')"
APK_NAME="BakaSU-$TAG-$ABI.apk"
mv "$APK_SRC" "$REL/$APK_NAME"; APK="$REL/$APK_NAME"
log "version $VERSION_NAME versionCode $VC tag $TAG cert size $CERT_SIZE sha256 $CERT_SHA"

RELEASE_ID="" PUBLISHED=0
cleanup() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$RELEASE_ID" ] && [ "$PUBLISHED" != 1 ]; then
        # a publish PATCH whose reply was lost may still have been applied: delete only a confirmed draft
        draft="$(api GET "/releases/$RELEASE_ID" | jget draft || true)"
        if [ "$draft" = True ]; then
            log "failure before publish: deleting draft release $RELEASE_ID"
            api DELETE "/releases/$RELEASE_ID" >/dev/null || true
        else
            log "failure: release $RELEASE_ID not deleted (draft state '${draft:-unreadable}'): check it by hand"
        fi
    fi
    rm -rf "$AUTH_DIR"
    exit "$rc"
}
trap cleanup EXIT

[ "$(http_code "/releases/tags/$TAG")" = 404 ] || die "release $TAG exists (or the check failed)"
[ "$(http_code "/tags/$TAG")" = 404 ] || die "tag $TAG exists (or the check failed)"
BODY="$(printf 'BakaSU manager %s (versionCode %s, package %s, %s only)\nBuilt by manager-release #%s from %s\nUpstream merged: Baka-SU/BakaSU@%s %s\n\nAPK sha256: %s  %s\nSigning certificate sha256: %s\nKernelSU dynamic manager signature: size %s (0x%x) hash %s' \
    "$VERSION_NAME" "$VC" "$PKG" "$ABI" "$RUN_NUMBER" "$SRC_SHA" "$UPSTREAM_BRANCH" "$UP_SHA" \
    "$APK_SHA" "$APK_NAME" "$CERT_SHA" "$CERT_SIZE" "$CERT_SIZE" "$CERT_SHA")"
REQ="$(python3 -I -c 'import json,sys;print(json.dumps({"tag_name":sys.argv[1],"target_commitish":"main","name":sys.argv[2],"body":sys.argv[3],"draft":True}))' "$TAG" "BakaSU $TAG" "$BODY")"
RELEASE_ID="$(api POST /releases -H 'Content-Type: application/json' -d "$REQ" | jget id)"
log "draft release $RELEASE_ID, uploading $APK_NAME"
ASSET_ID="$(api POST "/releases/$RELEASE_ID/assets?name=$APK_NAME" -F "attachment=@$APK" | jget id)"
ASSET_URL="$(api GET "/releases/$RELEASE_ID/assets/$ASSET_ID" | jget browser_download_url)"
# the token header goes to this forge only
case "$ASSET_URL" in "${SERVER_URL%/}"/*) ;; *) die "asset download URL is not on $SERVER_URL" ;; esac
log "downloading back $ASSET_URL"
curl -sSL --connect-timeout 30 --max-time 600 --fail-with-body -H "@$AUTH_H" -o "$REL/back.apk" "$ASSET_URL"
[ "$(sha "$REL/back.apk")" = "$APK_SHA" ] || die "downloaded asset sha256 differs"

# push the merge (fast-forward only), publish at the built commit
if [ "$SRC_SHA" != "$BASE_SHA" ]; then
    log "pushing merge $SRC_SHA"
    git_auth push -q origin "$SRC_SHA:refs/heads/main" || die "push of the merge failed (main moved?)"
fi
REQ="$(python3 -I -c 'import json,sys;print(json.dumps({"draft":False,"target_commitish":sys.argv[1]}))' "$SRC_SHA")"
api PATCH "/releases/$RELEASE_ID" -H 'Content-Type: application/json' -d "$REQ" >/dev/null
PUBLISHED=1
TAG_SHA="$(api GET "/tags/$TAG" | jget commit.sha)"
[ "$TAG_SHA" = "$SRC_SHA" ] || die "published tag $TAG points at $TAG_SHA, expected $SRC_SHA"
log "published $TAG: $APK_NAME sha256 $APK_SHA"
