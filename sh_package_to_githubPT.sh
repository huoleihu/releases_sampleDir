#!/bin/bash
# =============================================================================
#  sh_package_to_githubPT.sh — SampleDir 一键发布脚本
#
#  流程: 打包(mac dmg+pkg) → 收集桌面产物 → 进入 releases 仓库
#        → 生成 appcast.xml(显式区分 dmg/pkg/exe/msi) → 只提交 appcast.xml
#        → 打 tag + 推送 → 创建 GitHub Release(上传桌面产物为 asset)
#
#  设计原则:
#    • 安装包(dmg/pkg/exe/msi) **不进 git / 不走 LFS**，直接作为 GitHub Release asset 上传。
#      Git LFS 会把每个历史版本的安装包都累积到 git 历史里，导致每次 push 都上传几百 MB~几 GB。
#    • releases 仓库只保留 appcast.xml、README 和本脚本，保持几 KB 级别。
#    • 历史版本由 GitHub Release + tag 保留，下载直链稳定且走 CDN。
#
#  目标仓库: huoleihu/releases_sampleDir
#  (只放 appcast.xml 等元数据；Cloudflare Pages 有 25MB 限制，故装包走 GitHub Release)
#
#  用法:
#    ./sh_package_to_githubPT.sh                # 版本号自动读 gradle.properties(sampledir.version)，无需传参
#    ./sh_package_to_githubPT.sh 1.0.4          # 可选：手动覆盖版本号
#
#  前置:
#    ① gh CLI 已登录 (gh auth login)        —— 用于创建 Release
#    ② Windows 安装包需在 PD 虚拟机打好后，拷到本机 ~/Desktop
#       (mac 端本脚本负责打包；Windows 端无法在 mac 上构建)
#
#  关于 tag 覆盖:
#    同版本重发(重新发布)时，若 tag 已存在但指向旧 commit，脚本会 git tag -f + push -f 覆盖；
#    若已指向当前 commit 则跳过。换版本号(如 1.0.5)不会触碰旧 tag。
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
if [ "$PUBLISH_RELEASE" = "true" ] && ! command -v gh >/dev/null 2>&1; then
  echo "[error] 需要 gh CLI 来创建 Release，请先: gh auth login"
  exit 1
fi

# ---- 1) 打包 macOS (dmg + pkg 一并产出到桌面) ----
echo "[1/5] 打包 macOS ..."
( cd "$MAIN_PROJECT" && ./macPackageDMG.sh )

# ---- 2) 推断版本号 (默认读 gradle.properties，参数可覆盖) ----
if [ -z "$VERSION" ]; then
  VERSION="$(read_version_from_gradle)"
fi
if [ -z "$VERSION" ]; then
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

# ---- 4) 进入 releases 仓库，清理旧的安装包（不再提交到 git） ----
cd "$RELEASES_REPO"

# 把仓库根下旧的安装包清掉（之前版本若误提交过 LFS，这里也一并 git rm 掉）
# 当前版本的安装包只在 GitHub Release 里，不需要留在仓库工作树
echo "[*] 清理仓库根安装包 ..."
for ext in dmg pkg exe msi; do
  for old in "$RELEASES_REPO"/SampleDir-*.$ext; do
    [ -e "$old" ] || continue
    echo "    [del] $(basename "$old")"
    git rm -f --ignore-unmatch --quiet "$old" 2>/dev/null || rm -f "$old"
  done
done

# 移除旧的 LFS 规则：安装包不再走 git-lfs，避免以后误把二进制 commit 进去
if grep -q "filter=lfs" .gitattributes 2>/dev/null; then
  git rm -f --ignore-unmatch --quiet .gitattributes 2>/dev/null || rm -f .gitattributes
  echo "[ok] 已移除 .gitattributes LFS 规则（安装包不再进 git）"
fi

# ---- 5) 生成 appcast.xml (显式区分 dmg / pkg / exe / msi) ----
MAC_DMG=""; MAC_PKG=""; WIN_EXE=""; WIN_MSI=""
for f in "${PRODUCTS[@]}"; do
  case "$f" in
    *.dmg) MAC_DMG="$f";;
    *.pkg) MAC_PKG="$f";;
    *.exe) WIN_EXE="$f";;
    *.msi) WIN_MSI="$f";;
  esac
done

PUBDATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
if [ "$PUBLISH_RELEASE" = "true" ]; then
  BASE="https://github.com/$GH_REPO/releases/download/$TAG"
else
  BASE="https://raw.githubusercontent.com/$GH_REPO/$TAG"
fi

sha256_of() { [ -f "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo ""; }
gen_enc() {
  local url="$1" os="$2" itype="$3" file="$4" len sha
  len=$(stat -f%z "$file" 2>/dev/null || echo 0)
  sha=$(sha256_of "$file")
  # installerType 显式标注 dmg/pkg/exe/msi，不靠 URL 后缀判断
  echo "    <enclosure url=\"$url\" sparkle:os=\"$os\" installerType=\"$itype\" length=\"$len\" type=\"application/octet-stream\" sparkle:version=\"$VERSION\" sha256=\"$sha\" />"
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
[ -n "$MAC_DMG" ] && gen_enc "$BASE/$(basename "$MAC_DMG")" "macos"   "dmg" "$MAC_DMG"
[ -n "$MAC_PKG" ] && gen_enc "$BASE/$(basename "$MAC_PKG")" "macos"   "pkg" "$MAC_PKG"
[ -n "$WIN_EXE" ] && gen_enc "$BASE/$(basename "$WIN_EXE")" "windows" "exe" "$WIN_EXE"
[ -n "$WIN_MSI" ] && gen_enc "$BASE/$(basename "$WIN_MSI")" "windows" "msi" "$WIN_MSI"
echo '    </item>'
echo '  </channel>'
echo '</rss>'
} > appcast.xml
echo "[ok] 生成 appcast.xml (mac: ${MAC_DMG:-无}/${MAC_PKG:-无}  win: ${WIN_EXE:-无}/${WIN_MSI:-无})"

# ---- 6) 提交 + 打 tag(同版本重发可覆盖) + 推送 ----
# 注意：只提交 appcast.xml，安装包走 GitHub Release，不进 git
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git add appcast.xml
git commit -m "Release $TAG" || echo "[warn] 无新变更提交"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  EXISTING="$(git rev-parse "$TAG")"
  CURRENT="$(git rev-parse HEAD)"
  if [ "$EXISTING" != "$CURRENT" ]; then
    echo "[warn] tag $TAG 已存在且指向旧 commit，强制覆盖 (re-release)"
    git tag -f "$TAG"
    git push -f origin "$TAG"
  else
    echo "[ok] tag $TAG 已指向当前 commit，跳过"
  fi
else
  git tag "$TAG"
  echo "[ok] 打 tag $TAG"
  git push origin "$TAG"
fi
git push origin "$BRANCH"

# ---- 7) 创建 GitHub Release (下载链接最稳，无 LFS 带宽配额) ----
if [ "$PUBLISH_RELEASE" = "true" ]; then
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "[ok] Release $TAG 已存在，更新 asset"
  else
    gh release create "$TAG" --title "SampleDir $TAG" --notes "SampleDir $TAG" || true
  fi
  for f in "${PRODUCTS[@]}"; do
    if [ -e "$f" ]; then
      echo "[*] 上传 Release asset: $(basename "$f") ..."
      gh release upload "$TAG" "$f" --clobber
    fi
  done
fi

echo ""
echo "[done] tag=$TAG  仓库=$GH_REPO"
echo "       appcast.xml 已生成 (installerType 区分 dmg/pkg/exe/msi)"
echo "       安装包作为 Release asset 上传 (不走 git LFS)"
echo "       下载链接: $BASE"
