#!/bin/sh
# ────────────────────────────────────────────────────────────────
#  p12 → pem（sign_ipa.py 只吃 PEM）
#
#   ./tools/prep_cert.sh cert.p12 证书密码 app.mobileprovision
#
#  产出 cert/key.pem  cert/cert.pem  cert/app.mobileprovision
# ────────────────────────────────────────────────────────────────
set -eu

P12="${1:?用法: $0 证书.p12 密码 描述文件.mobileprovision}"
PASS="${2:-}"
PROV="${3:?需要 mobileprovision}"

mkdir -p cert
cp "$PROV" cert/app.mobileprovision

openssl pkcs12 -in "$P12" -nocerts -nodes -passin "pass:$PASS" -out cert/key.pem
openssl pkcs12 -in "$P12" -clcerts -nokeys -passin "pass:$PASS" -out cert/cert.pem

echo "· 证书信息"
openssl x509 -in cert/cert.pem -noout -subject -dates
echo "· 描述文件"
security cms -D -i cert/app.mobileprovision > cert/app.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Print :Name'           cert/app.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' cert/app.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' cert/app.plist 2>/dev/null || true

echo "✓ cert/ 就绪，现在可以 ./tools/build.sh --sign"
