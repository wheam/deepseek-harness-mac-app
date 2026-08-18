#!/usr/bin/env bash
# DeepSeek Harness for macOS — 一键安装脚本 / one-line installer.
#
# 用法 / usage:
#   curl -fsSL https://github.com/wheam/deepseek-harness-mac-app/releases/download/latest/install.sh | sh
#   sh install.sh [--no-open] [--dest <dir>]
#
# 原理：浏览器下载的 App 会被打上隔离（quarantine）属性，Gatekeeper 因此拦截；
# 本脚本用 curl 下载、校验代码签名后安装到 /Applications（无写权限时用
# ~/Applications），App 不带隔离属性，首次打开不会出现「无法验证开发者」警告。
set -e

REPO="wheam/deepseek-harness-mac-app"
BASE_URL="https://github.com/$REPO/releases/download/latest"
ZIP_NAME="DeepSeek-Harness.zip"
APP_NAME="DeepSeek Harness"

OPEN_APP=1
DEST=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-open) OPEN_APP=0 ;;
    --dest) DEST="$2"; shift ;;
    -h|--help)
      echo "usage: sh install.sh [--no-open] [--dest <dir>]"
      exit 0
      ;;
    *)
      echo "error: 未知参数: $1 (用 -h 查看用法)" >&2
      exit 2
      ;;
  esac
  shift
done

if [ -z "$DEST" ]; then
  if [ -w /Applications ]; then
    DEST="/Applications"
  else
    DEST="$HOME/Applications"
  fi
fi
mkdir -p "$DEST"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dsh-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "==> 下载 $ZIP_NAME …"
curl -fL --retry 3 -o "$TMP/$ZIP_NAME" "$BASE_URL/$ZIP_NAME"

echo "==> 解压并校验代码签名 …"
ditto -x -k "$TMP/$ZIP_NAME" "$TMP/unzipped"
APP_SRC="$TMP/unzipped/$APP_NAME.app"
[ -d "$APP_SRC" ] || { echo "error: 压缩包里没有找到 $APP_NAME.app" >&2; exit 1; }
codesign --verify --deep --strict "$APP_SRC"

if pgrep -x DeepSeekHarness >/dev/null 2>&1; then
  echo "==> 注意: App 正在运行，磁盘上的副本会被替换，下次启动生效。"
fi

echo "==> 安装到 $DEST …"
rm -rf "$DEST/$APP_NAME.app"
ditto "$APP_SRC" "$DEST/$APP_NAME.app"
xattr -dr com.apple.quarantine "$DEST/$APP_NAME.app" 2>/dev/null || true
codesign --verify --deep --strict "$DEST/$APP_NAME.app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || echo '?')"
BUILD_DATE="$(/usr/libexec/PlistBuddy -c 'Print :DSHBuildDate' "$DEST/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "==> 完成: $DEST/$APP_NAME.app (v$VERSION, build $BUILD_DATE)"
echo "    首次启动如未安装 dsh CLI，App 会弹窗引导一键安装: npm i -g @deepseek-ai/dsh"

if [ "$OPEN_APP" -eq 1 ]; then
  open "$DEST/$APP_NAME.app"
else
  echo "    手动打开: open \"$DEST/$APP_NAME.app\""
fi

echo "    如个别系统仍提示「无法验证开发者」: 系统设置 → 隐私与安全性 → 仍要打开。"
