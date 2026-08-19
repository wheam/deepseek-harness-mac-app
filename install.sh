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
NODE_INDEX_URL="https://nodejs.org/dist/index.json"
NODE_DIST_URL="https://nodejs.org/dist"
USER_NPM_PREFIX="$HOME/.local"
CURL="/usr/bin/curl"

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

ensure_user_bin_path() {
  export PATH="$USER_NPM_PREFIX/bin:$PATH"
  shell_name="$(basename "${SHELL:-/bin/zsh}")"
  if [ "$shell_name" = "fish" ]; then
    fish_conf="$HOME/.config/fish/conf.d/deepseek-harness-path.fish"
    mkdir -p "$(dirname "$fish_conf")"
    if [ ! -f "$fish_conf" ] || ! grep -Fq 'fish_add_path "$HOME/.local/bin"' "$fish_conf"; then
      printf '%s\n' 'fish_add_path "$HOME/.local/bin"' >> "$fish_conf"
    fi
    return
  fi

  case "$shell_name" in
    zsh) shell_rc="$HOME/.zprofile" ;;
    bash) shell_rc="$HOME/.bash_profile" ;;
    *) shell_rc="$HOME/.profile" ;;
  esac
  path_line='export PATH="$HOME/.local/bin:$PATH"'
  if [ ! -f "$shell_rc" ] || ! grep -Fq "$path_line" "$shell_rc"; then
    printf '\n# DeepSeek Harness user-global CLI\n%s\n' "$path_line" >> "$shell_rc"
  fi
}

install_official_node_lts() {
  echo "==> 未找到 npm，正在获取 Node.js LTS 官方安装包 …"
  "$CURL" -fL --retry 3 -o "$TMP/node-index.json" "$NODE_INDEX_URL"
  node_version="$(sed -n '/"lts":[[:space:]]*"/ {
    s/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p
    q
  }' "$TMP/node-index.json")"
  [ -n "$node_version" ] || {
    echo "error: 无法从 Node.js 官方索引解析 LTS 版本。" >&2
    exit 1
  }

  node_pkg="node-$node_version.pkg"
  node_base="$NODE_DIST_URL/$node_version"
  "$CURL" -fL --retry 3 -o "$TMP/SHASUMS256.txt" "$node_base/SHASUMS256.txt"
  "$CURL" -fL --retry 3 -o "$TMP/$node_pkg" "$node_base/$node_pkg"
  expected_sha="$(/usr/bin/awk -v file="$node_pkg" '$2 == file { print $1; exit }' "$TMP/SHASUMS256.txt")"
  actual_sha="$(/usr/bin/shasum -a 256 "$TMP/$node_pkg" | /usr/bin/awk '{ print $1 }')"
  [ -n "$expected_sha" ] && [ "$actual_sha" = "$expected_sha" ] || {
    echo "error: Node.js 安装包 SHA256 校验失败。" >&2
    exit 1
  }
  /usr/sbin/pkgutil --check-signature "$TMP/$node_pkg" >/dev/null

  echo "==> 安装 Node.js $node_version（macOS 将请求管理员密码）…"
  /usr/bin/sudo /usr/sbin/installer -pkg "$TMP/$node_pkg" -target /
  export PATH="/usr/local/bin:$PATH"
}

ensure_node_and_npm() {
  if command -v npm >/dev/null 2>&1; then
    return
  fi
  if command -v brew >/dev/null 2>&1; then
    echo "==> 未找到 npm，正在通过 Homebrew 安装 Node.js …"
    brew install node
    export PATH="$(brew --prefix node)/bin:$(brew --prefix)/bin:$PATH"
  else
    install_official_node_lts
  fi
  command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 || {
    echo "error: Node.js 安装完成后仍未找到 node/npm。" >&2
    exit 1
  }
}

npm_prefix_is_writable() {
  prefix="$1"
  if [ -d "$prefix" ]; then
    [ -w "$prefix" ] || return 1
    [ ! -d "$prefix/bin" ] || [ -w "$prefix/bin" ] || return 1
    [ ! -d "$prefix/lib/node_modules" ] || [ -w "$prefix/lib/node_modules" ] || return 1
    return 0
  fi
  [ -w "$(dirname "$prefix")" ]
}

ensure_global_dsh() {
  export PATH="/opt/homebrew/bin:/usr/local/bin:$USER_NPM_PREFIX/bin:$PATH"
  if command -v dsh >/dev/null 2>&1; then
    dsh_path="$(command -v dsh)"
    case "$dsh_path" in
      "$USER_NPM_PREFIX"/bin/*) ensure_user_bin_path ;;
    esac
    echo "==> 复用现有 dsh: $dsh_path ($("$dsh_path" --version 2>/dev/null || echo '?'))"
    return
  fi

  ensure_node_and_npm
  npm_prefix="$(npm prefix -g)"
  if npm_prefix_is_writable "$npm_prefix"; then
    echo "==> 全局安装 DeepSeek Harness CLI 到 $npm_prefix …"
    npm install -g @deepseek-ai/dsh@latest --no-audit --no-fund
  else
    echo "==> npm 全局目录不可写；安装共享用户级 CLI 到 $USER_NPM_PREFIX …"
    mkdir -p "$USER_NPM_PREFIX"
    npm install -g --prefix "$USER_NPM_PREFIX" @deepseek-ai/dsh@latest --no-audit --no-fund
    ensure_user_bin_path
  fi

  command -v dsh >/dev/null 2>&1 || {
    echo "error: npm 安装完成后仍未找到 dsh。" >&2
    exit 1
  }
  echo "==> dsh 已就绪: $(command -v dsh) ($(dsh --version))"
}

ensure_global_dsh

echo "==> 下载 $ZIP_NAME …"
"$CURL" -fL --retry 3 -o "$TMP/$ZIP_NAME" "$BASE_URL/$ZIP_NAME"

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
echo "    dsh CLI 与终端共用: $(command -v dsh)"

if [ "$OPEN_APP" -eq 1 ]; then
  open "$DEST/$APP_NAME.app"
else
  echo "    手动打开: open \"$DEST/$APP_NAME.app\""
fi

echo "    如个别系统仍提示「无法验证开发者」: 系统设置 → 隐私与安全性 → 仍要打开。"
