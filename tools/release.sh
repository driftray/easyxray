#!/usr/bin/env bash
# 打包发布文件：从当前提交生成 dist/easyxray.tar.gz 和 dist/easyxray.tar.gz.sha256
# tests、tools 等开发文件不打包（见 .gitattributes）。文件名固定，安装地址可以一直用 releases/latest/download/
# 用法：bash tools/release.sh [输出目录]
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-dist}
version=$(sed -n 's/^EZ_VERSION=//p' lib/common.sh)
[[ -z "$(git status --porcelain)" ]] || { echo "工作区有未提交的修改，请先提交" >&2; exit 1; }
mkdir -p "${out}"
git archive --format=tar HEAD | gzip -n -9 >"${out}/easyxray.tar.gz"
(cd "${out}" && shasum -a 256 easyxray.tar.gz >easyxray.tar.gz.sha256)
echo "easyxray ${version}（提交 $(git rev-parse --short HEAD)）"
cat "${out}/easyxray.tar.gz.sha256"
echo "发布时 tag 用 v${version}，上传 ${out}/ 下的两个文件"
