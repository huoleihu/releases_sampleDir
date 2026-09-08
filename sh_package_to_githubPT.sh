#!/bin/bash
# =============================================================================
#  sh_package_to_githubPT.sh — SampleDir 一键发布脚本
#
#  流程: 打包(mac dmg+pkg) → 收集桌面产物 → 复制到 releases 仓库
#        → 生成 appcast.xml(区分 mac / windows) → 提交 + 打 tag + 推送
#        → 创建 GitHub Release(下载链接最稳，走 Release 直链)
#
#  目标仓库: huoleihu/releases_sampleDir
#  (专放 dmg/pkg/exe 等安装包；Cloudflare Pages 有 25MB 限制，故装包走此仓库)
#
#  用法:
#    ./sh_package_to_githubPT.sh                # 版本号自动读 gradle.properties(sampledir.version)，无需传参
#    ./sh_package_to_githubPT.sh 1.0.4          # 可选：手动覆盖版本号
#
#  前置:
#    ① git-lfs 已装 (brew install git-lfs) —— 160MB dmg 超 GitHub 单文件 100MB，必须走 LFS
#    ② gh CLI 已登录 (gh auth login)        —— 用于创建 Release
#    ③ Windows 安装包需在 PD 虚拟机打好后，拷到本机 ~/Desktop
#       (mac 端本脚本负责打包；Windows 端无法在 mac 上构建)
# =============================================================================
set -e

MAIN_PROJECT="/Users/huoleihu/ai_workbuddy/kotlin_sampleDir"
RELEASES_REPO="/Users/huoleihu/ai_workbuddy/kotlin_sampleDir_releases"
GH_REPO="huoleihu/releases_sampleDir"
DESKTOP="$HOME/Desktop"

VERSION="${1:-}"            # 可选手动覆盖；默认读主工程 gradle.properties
PUBLISH_RELEASE="${PUBLISH_RELEASE:-true}"

# 版本号主来源：主工程 gradle.properties 的 sampledir.version（与 macPackageDMG.sh 同源）
# 用户在此处管版本号，脚本无需显式传参；桌面残留旧版本也不会误读。
read_version_from_gradle() {
  local f="$MAIN_PROJECT/gradle.properties"
  [ -f "$f" ] || return 1
  grep '^sampledir.version' "$f" | cut -d= -f2 | tr -d '[:space:]'
}

# ---- 前置检查 ----
if ! command -v git-lfs >/dev/null 2>&1; then
  echo "[error] 需要 git-lfs，请先执行: brew install git-lfs && git lfs install"
  exit 1
fi
if [ "$PUBLISH_RELEASE" = "true" ] && ! command -v gh >/dev/null 2>&1; then
  echo "[error] 需要 gh CLI 来创建 Release，请先: gh auth login"
  exit 1
fi

# ---- 1) 打包 macOS (dmg + pkg 一并产出到桌面) ----
echo "[1/6] 打包 macOS ..."
( cd "$MAIN_PROJECT" && ./macPackageDMG.sh )

# ---- 2) 推断版本号 (默认读 gradle.properties，参数可覆盖) ----
if [ -z "$VERSION" ]; then
  VERSION="$(read_version_from_gradle)"
fi
if [ -z "$VERSION" ]; then
  # 兜底：从桌面产物文件名推断（仅在 gradle.properties 未配置时）
  FIRST=$(ls "$DESKTOP"/SampleDir-*.dmg "$DESKTOP"/SampleDir-*.pkg "$DESKTOP"/SampleDir-*.exe 2>/dev/null | head -1)
  if [ -z "$FIRST" ]; then
    echo "[error] 无法从 gradle.properties 读取 sampledir.version，且桌面无产物，请先打包"
    exit 1
  fi
  VERSION="$(basename "$FIRST" | sed -E 's/.*SampleDir-([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
  echo "[warn] 用桌面文件名推断版本=$VERSION（建议配置 gradle.properties 的 sampledir.version）"
fi
TAG="v$VERSION"
echo "[ok] 版本=$VERSION  tag=$TAG"

# ---- 3) 收集当前版本桌面产物 (不含便携版) ----
PRODUCTS=()
for ext in dmg pkg exe msi; do
  for f in "$DESKTOP"/SampleDir-${VERSION}-*.$ext; do [ -e "$f" ] && PRODUCTS+=("$f"); done
done

if [ ${#PRODUCTS[@]} -eq 0 ]; then
  echo "[error] 桌面未找到 SampleDir-${VERSION}-* 安装包(dmg/pkg/exe/msi)，请先打包"
  exit 1
fi
echo "[ok] 收集到 ${#PRODUCTS[@]} 个产物:"
printf '      %s\n' "${PRODUCTS[@]/#$DESKTOP/~/Desktop}"

# mac 至少要有 dmg 或 pkg
if ! ls "$DESKTOP"/SampleDir-${VERSION}-*.dmg >/dev/null 2>&1 && \
   ! ls "$DESKTOP"/SampleDir-${VERSION}-*.pkg >/dev/null 2>&1; then
  echo "[error] macOS 安装包未生成，打包可能失败，请检查 macPackageDMG.sh 输出"
  exit 1
fi

# ---- 4) 复制到 releases 仓库 + Git LFS ----
cd "$RELEASES_REPO"
git lfs install >/dev/null 2>&1 || true

if ! grep -q "filter=lfs" .gitattributes 2>/dev/null; then
cat > .gitattributes <<'EOF'
*.dmg filter=lfs diff=lfs merge=lfs -text
*.pkg filter=lfs diff=lfs merge=lfs -text
*.exe filter=lfs diff=lfs merge=lfs -text
*.msi filter=lfs diff=lfs merge=lfs -text
EOF
  git add .gitattributes
fi

mkdir -p "$VERSION"
for f in "${PRODUCTS[@]}"; do
  cp -f "$f" "$VERSION/"
  echo "[ok] 复制 $(basename "$f")"
done

# ---- 5) 生成 appcast.xml (区分 mac / windows) ----
MAC_DMG=""; MAC_PKG=""; WIN_EXE=""; WIN_MSI=""
for f in "$VERSION"/SampleDir-*; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  case "$b" in
    *.dmg) MAC_DMG="$b";;
    *.pkg) MAC_PKG="$b";;
    *.exe) WIN_EXE="$b";;
    *.msi) WIN_MSI="$b";;
  esac
done

PUBDATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
if [ "$PUBLISH_RELEASE" = "true" ]; then
  BASE="https://github.com/$GH_REPO/releases/download/$TAG"
else
  BASE="https://raw.githubusercontent.com/$GH_REPO/$TAG/$VERSION"
fi

sha256_of() { [ -f "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo ""; }
gen_enc() {
  local url="$1" os="$2" file="$3" len sha
  len=$(stat -f%z "$VERSION/$file" 2>/dev/null || echo 0)
  sha=$(sha256_of "$VERSION/$file")
  echo "    <enclosure url=\"$url\" sparkle:os=\"$os\" length=\"$len\" type=\"application/octet-stream\" sparkle:version=\"$VERSION\" sha256=\"$sha\" />"
}

{
echo '<?xml version="1.0" encoding="UTF-8"?>'
echo '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">'
echo '  <channel>'
echo "    <title>SampleDir</title>"
echo "    <item>"
echo "      <title>$VERSION</title>"
echo "      <pubDate>$PUBDATE</pubDate>"
echo "      <sparkle:version>$VERSION</sparkle:version>"
[ -n "$MAC_DMG" ] && gen_enc "$BASE/$MAC_DMG" "macos"   "$MAC_DMG"
[ -n "$MAC_PKG" ] && gen_enc "$BASE/$MAC_PKG" "macos"   "$MAC_PKG"
[ -n "$WIN_EXE" ] && gen_enc "$BASE/$WIN_EXE" "windows" "$WIN_EXE"
[ -n "$WIN_MSI" ] && gen_enc "$BASE/$WIN_MSI" "windows" "$WIN_MSI"
echo '    </item>'
echo '  </channel>'
echo '</rss>'
} > appcast.xml
echo "[ok] 生成 appcast.xml (mac: ${MAC_DMG:-无}/${MAC_PKG:-无}  win: ${WIN_EXE:-无}/${WIN_MSI:-无})"

# ---- 6) 提交 + 打 tag + 推送 ----
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git add -A
git commit -m "Release $TAG" || echo "[warn] 无新变更提交"
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  git tag "$TAG"
  echo "[ok] 打 tag $TAG"
fi
git push origin "$BRANCH"
git push origin "$TAG" || true

# ---- 7) 创建 GitHub Release (下载链接最稳，无 LFS 带宽配额) ----
if [ "$PUBLISH_RELEASE" = "true" ]; then
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "[ok] Release $TAG 已存在"
  else
    gh release create "$TAG" --title "SampleDir $TAG" --notes "SampleDir $TAG" || true
  fi
  for f in "$VERSION"/SampleDir-*; do
    [ -e "$f" ] && gh release upload "$TAG" "$f" --clobber || true
  done
fi

echo ""
echo "[done] tag=$TAG  仓库=$GH_REPO"
echo "       appcast.xml 已生成 (客户端可改读此 XML 做版本检测与更新)"
echo "       下载链接: $BASE"
