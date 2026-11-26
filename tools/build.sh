#!/bin/sh
# ────────────────────────────────────────────────────────────────
#  macOS 侧一键出 IPA
#
#   ./tools/build.sh                 # 未签名 IPA（可直接拿去 Sideloadly 重签）
#   ./tools/build.sh --sign          # 编完直接用 ../ipa-signer 重签成可安装 IPA
#
#  需要：Xcode 15+。不需要 xcodegen —— 工程由 tools/gen_xcodeproj.py 生成。
# ────────────────────────────────────────────────────────────────
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

SIGN=0
[ "${1:-}" = "--sign" ] && SIGN=1

TEAM_ID="${TEAM_ID:-TEAMID}"
BUNDLE_ID="${BUNDLE_ID:-com.local.nfclab}"
SWIFT_FLAGS="${SWIFT_FLAGS:-}"
SCHEME=NFCCardLab
BUILD=build

command -v xcodebuild >/dev/null 2>&1 || { echo "缺少 Xcode 命令行工具：xcode-select --install" >&2; exit 1; }

echo "· 生成 Xcode 工程"
python3 tools/gen_xcodeproj.py --team "$TEAM_ID" --bundle-id "$BUNDLE_ID" \
        --swift-flags "$SWIFT_FLAGS" >/dev/null

echo "· 编译（Release, arm64, iOS 16+）"
rm -rf "$BUILD/dd"
xcodebuild \
  -project NFCCardLab.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD/dd" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP="$BUILD/dd/Build/Products/Release-iphoneos/$SCHEME.app"
[ -d "$APP" ] || { echo "编译产物不存在: $APP" >&2; exit 1; }
echo "✓ $APP"

echo "· 打 IPA"
python3 tools/pack_ipa.py "$APP" "$BUILD/$SCHEME-unsigned.ipa"

if [ "$SIGN" = "1" ]; then
  echo "· 重签"
  python3 ../ipa-signer/sign_ipa.py \
    --ipa "$BUILD/$SCHEME-unsigned.ipa" \
    --key "${KEY:-cert/key.pem}" \
    --cert "${CERT:-cert/cert.pem}" \
    --provision "${PROV:-cert/app.mobileprovision}" \
    --bundle-id "$BUNDLE_ID" \
    --out "$BUILD/$SCHEME-signed.ipa"

  echo "· 校验"
  python3 ../ipa-signer/sign_ipa.py --verify "$BUILD/$SCHEME-signed.ipa"
  echo "✓ $BUILD/$SCHEME-signed.ipa"
else
  echo "✓ $BUILD/$SCHEME-unsigned.ipa"
  echo "  拖进 Sideloadly 用你的证书签，或加 --sign 走本地重签"
fi
