#!/usr/bin/env bash
# Build an adhoc-signed IPA on a macOS GitHub Actions runner.
# The result is a re-signing input, not a directly installable device build.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
DERIVED="$ROOT/build/derived"
STAGE="$ROOT/build/stage"
APPNAME="WQtool.app"
IPA="$ROOT/build/WQtool-adhoc.ipa"

mkdir -p "$ROOT/build" "$STAGE/Payload"
if [[ -d "$STAGE/Payload/$APPNAME" ]]; then rm -rf "$STAGE/Payload/$APPNAME"; fi

echo "== toolchain =="
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version

echo "== xcodebuild =="
BUILD_ARGS=(
  -project "$ROOT/WQtool.xcodeproj"
  -scheme WQtool
  -configuration Release
  -sdk iphoneos
  -destination 'generic/platform=iOS'
  -derivedDataPath "$DERIVED"
  CODE_SIGNING_ALLOWED=NO
)
# The runner selects an Xcode with an iOS 26+ SDK (macos-26). The deployment
# target is pinned to 26.0 so both MinimumOSVersion and LC_BUILD_VERSION agree.
if [[ -n "${DEPLOYMENT_TARGET:-}" ]]; then
  BUILD_ARGS+=("IPHONEOS_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET")
  echo "deployment target override: $DEPLOYMENT_TARGET"
fi
BUILD_ARGS+=(build)
xcodebuild "${BUILD_ARGS[@]}"

PRODUCT="$DERIVED/Build/Products/Release-iphoneos/$APPNAME"
if [[ ! -d "$PRODUCT" ]]; then
  echo "missing product: $PRODUCT" >&2
  exit 1
fi
cp -R "$PRODUCT" "$STAGE/Payload/$APPNAME"

echo "== align MinimumOSVersion with the linked deployment target =="
PLIST="$STAGE/Payload/$APPNAME/Info.plist"
TARGET_MIN="${DEPLOYMENT_TARGET:-26.0}"
/usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $TARGET_MIN" "$PLIST" >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string $TARGET_MIN" "$PLIST" >/dev/null
echo "MinimumOSVersion = $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")"

echo "== adhoc codesign (App Group entitlement is mandatory) =="
codesign --force --sign - --timestamp=none \
  --entitlements "$ROOT/Resources/AppGroup.entitlements" \
  "$STAGE/Payload/$APPNAME"
codesign --verify --deep --strict "$STAGE/Payload/$APPNAME"
codesign -d --entitlements :- "$STAGE/Payload/$APPNAME" > "$ROOT/build/entitlements.plist"

echo "== package =="
rm -f "$IPA" "$IPA.tmp"
(cd "$STAGE" && /usr/bin/zip -qry "$IPA.tmp" Payload)
/usr/bin/unzip -t "$IPA.tmp" > "$ROOT/build/zip-validation.log"
mv "$IPA.tmp" "$IPA"
shasum -a 256 "$IPA" | tee "$IPA.sha256"

echo "== verify =="
python3 "$ROOT/Scripts/verify-ipa.py" "$IPA" | tee "$ROOT/build/verify.json"
printf 'IPA: %s\nadhoc 签名验签通过；它只是重签输入，普通真机安装需匹配证书/描述文件/App Group。\n' "$IPA"
