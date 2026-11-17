#!/usr/bin/env bash
# 构建 iOS device(arm64) SILK v3 静态库（微信 / QQ 的 .aud 语音格式编码器）。
# 产物：Vendor/lib/libSKP_SILK_SDK.a、Vendor/include/silk/*.h
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
WORK="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/silk-deps-build"
MIN_IOS="${MIN_IOS:-26.0}"

rm -rf "$WORK"
mkdir -p "$WORK" "$VENDOR/lib" "$VENDOR/include/silk"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"
ARCH_FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=${MIN_IOS}"

echo "== 环境 =="
echo "SDK: $SDK"
"$CLANG" --version | head -1

echo "== SILK: silk-v3-decoder =="
SILK_REPO="$WORK/silk-v3"
git clone --depth 1 https://github.com/kn007/silk-v3-decoder "$SILK_REPO"
SILK_SRC="$SILK_REPO/silk"

if [ ! -d "$SILK_SRC/src" ]; then
  echo "silk 源码目录缺失：$SILK_SRC"
  exit 1
fi

mkdir -p "$WORK/silkobj"
for source in "$SILK_SRC"/src/*.c; do
  "$CLANG" -c $ARCH_FLAGS -O2 -fPIC \
    -I"$SILK_SRC/interface" \
    -I"$SILK_SRC/src" \
    "$source" -o "$WORK/silkobj/$(basename "${source%.c}").o"
done
ar rcs "$VENDOR/lib/libSKP_SILK_SDK.a" "$WORK"/silkobj/*.o
cp "$SILK_SRC"/interface/*.h "$VENDOR/include/silk/"

echo "== 产物校验 =="
ls -lh "$VENDOR/lib"
lipo -info "$VENDOR/lib/libSKP_SILK_SDK.a"
nm -gU "$VENDOR/lib/libSKP_SILK_SDK.a" | grep -c "SKP_Silk_SDK_Encode"
ls "$VENDOR/include/silk"
