#!/usr/bin/env bash
#
# Pack repacked JRE tarballs into EdgeCube .ecpkg runtime packages.
#
# This script runs after repack_jre.sh. It reads the split tarballs
# (universal.tar.xz + bin-<arch>.tar.xz) produced by repack_jre.sh and
# produces EdgeCube-importable .ecpkg files:
#
#   <id>-arm64.ecpkg    single-arch (universal merged into arch dir)
#   <id>-arm.ecpkg      single-arch
#   <id>-x86_64.ecpkg   single-arch
#   <id>-multi.ecpkg    multi-arch (universal/ + per-arch dirs)
#
# The ecpkg spec only supports arm64, arm, x86_64 — NOT x86. The x86
# tarball from repack_jre.sh is ignored here.
#
# Usage:
#   ./pack_ecpkg.sh [input_dir] [output_dir]
#
# Environment overrides:
#   ECPKG_ID              runtime id in manifest (default: jre8)
#   ECPKG_NAME            display name (default: OpenJDK 8)
#   ECPKG_AUTHOR          package author (default: EdgeCube)
#   ECPKG_HOMEPAGE        homepage URL (default: https://openjdk.org/)
#   ECPKG_REPOSITORY      repository URL
#   ECPKG_MIN_APP_VERSION minimum EdgeCube versionCode (default: 6)
#   ECPKG_DESCRIPTION     package description
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────
ECPKG_ID="${ECPKG_ID:-jre8}"
ECPKG_NAME="${ECPKG_NAME:-OpenJDK 8}"
ECPKG_AUTHOR="${ECPKG_AUTHOR:-EdgeCube}"
ECPKG_HOMEPAGE="${ECPKG_HOMEPAGE:-https://openjdk.org/}"
ECPKG_REPOSITORY="${ECPKG_REPOSITORY:-https://github.com/venti1112/EdgeCubePackage-JRE}"
ECPKG_MIN_APP_VERSION="${ECPKG_MIN_APP_VERSION:-6}"
ECPKG_DESCRIPTION="${ECPKG_DESCRIPTION:-OpenJDK 8 runtime for EdgeCube.}"

INPUT_DIR="${1:-${ECPKG_INPUT_DIR:-$PWD}}"
OUTPUT_DIR="${2:-${ECPKG_OUTPUT_DIR:-$INPUT_DIR/ecpkg}}"

# ecpkg-supported archs (must match ecpkg-spec §8). These map 1:1 to the
# bin-<arch>.tar.xz names produced by repack_jre.sh.
ARCHS=(arm64 arm x86_64)

# ── Validation ────────────────────────────────────────────────────────────
[[ "$ECPKG_ID" =~ ^[A-Za-z0-9._-]+$ && "$ECPKG_ID" != .* ]] || {
  echo "error: ECPKG_ID must match ^[A-Za-z0-9._-]+$ and must not start with '.'" >&2
  exit 1
}
[[ "$ECPKG_MIN_APP_VERSION" =~ ^[0-9]+$ ]] || {
  echo "error: ECPKG_MIN_APP_VERSION must be an integer" >&2
  exit 1
}

INPUT_DIR="$(cd "$INPUT_DIR" && pwd)"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

[[ -f "$INPUT_DIR/universal.tar.xz" ]] || {
  echo "error: universal.tar.xz not found in $INPUT_DIR" >&2
  echo "   Hint: run repack_jre.sh first to produce split tarballs." >&2
  exit 1
}
for arch in "${ARCHS[@]}"; do
  [[ -f "$INPUT_DIR/bin-$arch.tar.xz" ]] || {
    echo "error: bin-$arch.tar.xz not found in $INPUT_DIR" >&2
    exit 1
  }
done

# ── Helper: JSON string escape ────────────────────────────────────────────
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

# ── Helper: write edgecube-package.json manifest ──────────────────────────
#
# write_manifest <manifest_path> <universal_dir|""> <arch> [<arch> ...]
#
# When universal_dir is empty, no universalDir field is written (single-arch
# packages where universal files are merged into the arch directory).
write_manifest() {
  local manifest="$1"
  local universal_dir="$2"
  shift 2
  local archs=("$@")

  local version_json name_json desc_json author_json homepage_json repository_json
  version_json="$(json_escape "$VERSION")"
  name_json="$(json_escape "$ECPKG_NAME")"
  desc_json="$(json_escape "$ECPKG_DESCRIPTION")"
  author_json="$(json_escape "$ECPKG_AUTHOR")"
  homepage_json="$(json_escape "$ECPKG_HOMEPAGE")"
  repository_json="$(json_escape "$ECPKG_REPOSITORY")"

  {
    cat <<EOF
{
  "formatVersion": 1,
  "type": "jre",
  "id": "$ECPKG_ID",
  "name": "$name_json",
  "version": "$version_json",
  "description": "$desc_json",
  "author": "$author_json",
  "homepage": "$homepage_json",
  "repository": "$repository_json",
EOF

    if [[ -n "$universal_dir" ]]; then
      printf '  "universalDir": "%s",\n' "$universal_dir"
    fi

    cat <<EOF
  "arch": {
EOF

    for i in "${!archs[@]}"; do
      local arch="${archs[$i]}"
      local comma=","
      [ "$i" -eq $((${#archs[@]} - 1)) ] && comma=""
      printf '    "%s": { "dir": "%s" }%s\n' "$arch" "$arch" "$comma"
    done

    cat <<EOF
  },
  "launcher": {
    "type": "jli",
    "lib": "lib/libjli.so"
  },
  "env": {
    "JAVA_HOME": "\${RUNTIME_DIR}",
    "PATH": "\${RUNTIME_DIR}/bin"
  },
  "minAppVersion": $ECPKG_MIN_APP_VERSION
}
EOF
  } > "$manifest"
}

# ── Helper: zip a staging directory into an .ecpkg ────────────────────────
zip_dir() {
  local src="$1"
  local dst="$2"
  rm -f "$dst"

  if command -v zip >/dev/null 2>&1; then
    (cd "$src" && zip -qr "$dst" edgecube-package.json */)
    return
  fi

  local py=""
  if command -v python3 >/dev/null 2>&1; then
    py="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    py="$(command -v python)"
  fi
  [ -n "$py" ] || { echo "error: zip or python is required to create .ecpkg packages" >&2; exit 1; }

  "$py" - "$src" "$dst" <<'PY'
import os
import sys
import zipfile

src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(src):
        dirs.sort()
        files.sort()
        rel_root = os.path.relpath(root, src)
        if rel_root != ".":
            zf.write(root, rel_root.replace(os.sep, "/") + "/")
        for name in files:
            path = os.path.join(root, name)
            rel = os.path.relpath(path, src).replace(os.sep, "/")
            zf.write(path, rel)
PY
}

# ── 1. Prepare staging directories ────────────────────────────────────────
STAGING="$OUTPUT_DIR/.staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/multi/universal"

echo ">>> extracting universal.tar.xz"
tar xJf "$INPUT_DIR/universal.tar.xz" -C "$STAGING/multi/universal"

for arch in "${ARCHS[@]}"; do
  echo ">>> extracting bin-$arch.tar.xz"

  # Multi-arch staging: arch files go into <arch>/ (universal is separate)
  mkdir -p "$STAGING/multi/$arch"
  tar xJf "$INPUT_DIR/bin-$arch.tar.xz" -C "$STAGING/multi/$arch"

  # Single-arch staging: merge universal + arch into one <arch>/ directory
  mkdir -p "$STAGING/single-$arch/$arch"
  cp -a "$STAGING/multi/universal/." "$STAGING/single-$arch/$arch/"
  tar xJf "$INPUT_DIR/bin-$arch.tar.xz" -C "$STAGING/single-$arch/$arch"
done

# ── 2. Extract JDK version from the release file ─────────────────────────
# The release file is inside bin-<arch>.tar.xz (put there by repack_jre.sh's
# makearch function). It contains JAVA_VERSION="21.0.1+12" etc.
RELEASE_FILE="$STAGING/multi/arm64/release"
if [[ ! -f "$RELEASE_FILE" ]]; then
  RELEASE_FILE="$STAGING/multi/x86_64/release"
fi
VERSION=""
if [[ -f "$RELEASE_FILE" ]]; then
  VERSION="$(grep '^JAVA_VERSION=' "$RELEASE_FILE" | head -1 | sed 's/^JAVA_VERSION="//;s/"$//')"
fi
if [[ -z "$VERSION" ]]; then
  # Fallback to the version file written by repack_jre.sh (commit SHA or date)
  VERSION="$(cat "$INPUT_DIR/version" 2>/dev/null || echo "unknown")"
fi
echo "    version = $VERSION"

# ── 3. Create single-arch .ecpkg packages ─────────────────────────────────
# Each single-arch package has the complete JRE (universal + arch) merged
# into one directory. No universalDir in the manifest.
mkdir -p "$OUTPUT_DIR"
for arch in "${ARCHS[@]}"; do
  write_manifest "$STAGING/single-$arch/edgecube-package.json" "" "$arch"
  zip_dir "$STAGING/single-$arch" "$OUTPUT_DIR/${ECPKG_ID}-${arch}.ecpkg"
  echo "    -> $OUTPUT_DIR/${ECPKG_ID}-${arch}.ecpkg"
done

# ── 4. Create multi-arch .ecpkg package ───────────────────────────────────
# The multi-arch package has universal/ + per-arch directories. The manifest
# declares universalDir so EdgeCube extracts universal first, then the
# device's arch directory on top.
write_manifest "$STAGING/multi/edgecube-package.json" "universal" "${ARCHS[@]}"
zip_dir "$STAGING/multi" "$OUTPUT_DIR/${ECPKG_ID}-multi.ecpkg"
echo "    -> $OUTPUT_DIR/${ECPKG_ID}-multi.ecpkg"

# ── 5. Clean up ───────────────────────────────────────────────────────────
rm -rf "$STAGING"

echo ""
echo "done. version=$VERSION  archs=${ARCHS[*]}"
echo "packages: $OUTPUT_DIR"
echo "import ${ECPKG_ID}-<arch>.ecpkg or ${ECPKG_ID}-multi.ecpkg from EdgeCube's runtime page."
