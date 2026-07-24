#!/usr/bin/env bash
#
# build_dav1d.sh — build dav1d (VideoLAN's AV1 decoder, BSD-2-Clause) as a
# static arm64 iOS device XCFramework, vendored into Vendor/dav1d.xcframework.
#
# MAINTAINER-ONLY. This script requires meson + ninja on top of the Xcode
# command line tools:
#
#     brew install meson ninja
#
# Contributors building the app do NOT need any of this: the resulting
# XCFramework is a prebuilt binary checked into Vendor/ and consumed as-is.
# meson/ninja must never become a requirement for anyone but the person
# refreshing the vendored binary.
#
# Usage: Scripts/build_dav1d.sh
#
set -euo pipefail

# --- Pinned source ----------------------------------------------------------
# dav1d release tarball + its SHA-256. Pinned so the build is reproducible
# and tamper-evident. Trust-on-first-use: this hash was computed by
# downloading this exact tarball from downloads.videolan.org and hashing it
# locally with `shasum -a 256` (there is no upstream detached signature to
# verify against) — this pin *is* the root of trust from here on. Bump both
# values together when updating dav1d.
DAV1D_VERSION="1.5.4"
DAV1D_SHA256="686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5"

DAV1D_URL="https://downloads.videolan.org/pub/videolan/dav1d/${DAV1D_VERSION}/dav1d-${DAV1D_VERSION}.tar.xz"
IOS_MIN_VERSION="12.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/dav1d"
VENDOR_DIR="${ROOT_DIR}/Vendor"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- Tool preflight (maintainer-only) ----------------------------------------
missing=()
for tool in meson ninja xcrun; do
  command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
done
if [ "${#missing[@]}" -gt 0 ]; then
  die "maintainer-only script; brew install meson ninja (missing: ${missing[*]})"
fi
# Note: dav1d's arm64 asm is assembled by clang itself (gas syntax) — nasm
# is an x86-only requirement upstream and is NOT needed for this build.

mkdir -p "${BUILD_DIR}" "${VENDOR_DIR}"

# --- Download + verify --------------------------------------------------------
TARBALL="${BUILD_DIR}/dav1d-${DAV1D_VERSION}.tar.xz"
if [ ! -f "${TARBALL}" ]; then
  log "Downloading dav1d ${DAV1D_VERSION}"
  curl -fL --retry 3 -o "${TARBALL}" "${DAV1D_URL}"
fi

log "Verifying checksum"
ACTUAL_SHA256="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
if [ "${ACTUAL_SHA256}" != "${DAV1D_SHA256}" ]; then
  rm -f "${TARBALL}"
  die "checksum mismatch for dav1d-${DAV1D_VERSION}.tar.xz: expected ${DAV1D_SHA256}, got ${ACTUAL_SHA256}"
fi

SRC_DIR="${BUILD_DIR}/dav1d-${DAV1D_VERSION}"
if [ ! -d "${SRC_DIR}" ]; then
  log "Extracting source"
  tar -xf "${TARBALL}" -C "${BUILD_DIR}"
fi

# --- Cross file for iOS device (arm64) ----------------------------------------
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
CC_BIN="$(xcrun --sdk iphoneos --find clang)"
CXX_BIN="$(xcrun --sdk iphoneos --find clang++)"
AR_BIN="$(xcrun --sdk iphoneos --find ar)"
STRIP_BIN="$(xcrun --sdk iphoneos --find strip)"

CROSS_FILE="${BUILD_DIR}/ios-arm64-cross.ini"
cat >"${CROSS_FILE}" <<EOF
[binaries]
c = '${CC_BIN}'
cpp = '${CXX_BIN}'
ar = '${AR_BIN}'
strip = '${STRIP_BIN}'

[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '${SDK_PATH}', '-miphoneos-version-min=${IOS_MIN_VERSION}']
c_link_args = ['-arch', 'arm64', '-isysroot', '${SDK_PATH}', '-miphoneos-version-min=${IOS_MIN_VERSION}']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF
# No bitcode flags above (no -fembed-bitcode / -fembed-bitcode-marker):
# bitcode is not part of this build.

# --- meson + ninja build ------------------------------------------------------
MESON_BUILD_DIR="${BUILD_DIR}/build-ios-arm64"
DESTDIR="${BUILD_DIR}/install"

MESON_SETUP_ARGS=(
  --cross-file "${CROSS_FILE}"
  -Ddefault_library=static
  -Denable_tools=false
  -Denable_tests=false
  -Denable_examples=false
  --buildtype release
  --prefix /
  --libdir lib
  --includedir include
)

log "Configuring meson"
if [ -d "${MESON_BUILD_DIR}" ]; then
  meson setup --reconfigure "${MESON_SETUP_ARGS[@]}" "${MESON_BUILD_DIR}" "${SRC_DIR}"
else
  meson setup "${MESON_SETUP_ARGS[@]}" "${MESON_BUILD_DIR}" "${SRC_DIR}"
fi

log "Building with ninja"
ninja -C "${MESON_BUILD_DIR}"

log "Installing to staging dir (for clean headers)"
rm -rf "${DESTDIR}"
DESTDIR="${DESTDIR}" meson install -C "${MESON_BUILD_DIR}"

STATIC_LIB="${DESTDIR}/lib/libdav1d.a"
HEADERS_DIR="${DESTDIR}/include"
[ -f "${STATIC_LIB}" ] || die "expected static library not found: ${STATIC_LIB}"
[ -d "${HEADERS_DIR}" ] || die "expected headers dir not found: ${HEADERS_DIR}"

# --- Assemble XCFramework ------------------------------------------------------
# Device (arm64 iphoneos) slice only for now. If a simulator slice is ever
# needed, add a second cross-file (iphonesimulator SDK via the same
# `xcrun --sdk iphonesimulator --find ...` pattern), build a second static
# lib from it, and pass a second -library/-headers pair to
# -create-xcframework below.
XCFRAMEWORK_PATH="${VENDOR_DIR}/dav1d.xcframework"
rm -rf "${XCFRAMEWORK_PATH}"

log "Creating XCFramework"
xcodebuild -create-xcframework \
  -library "${STATIC_LIB}" -headers "${HEADERS_DIR}" \
  -output "${XCFRAMEWORK_PATH}"

# --- License + version metadata -------------------------------------------------
cp "${SRC_DIR}/COPYING" "${VENDOR_DIR}/dav1d-LICENSE"
cat >"${VENDOR_DIR}/dav1d-VERSION" <<EOF
dav1d ${DAV1D_VERSION}
source: ${DAV1D_URL}
sha256: ${DAV1D_SHA256}
EOF

# --- Report ----------------------------------------------------------------------
LIB_SIZE="$(du -h "${STATIC_LIB}" | awk '{print $1}')"
XCFRAMEWORK_SIZE="$(du -sh "${XCFRAMEWORK_PATH}" | awk '{print $1}')"
log "libdav1d.a size: ${LIB_SIZE}"
log "dav1d.xcframework size: ${XCFRAMEWORK_SIZE}"
log "XCFramework path: ${XCFRAMEWORK_PATH}"
