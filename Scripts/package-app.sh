#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
build_dir="$project_dir/.build"
app_dir="$build_dir/app/Michel Mails.app"

cd "$project_dir"
swift build -c "$configuration"

binary_path=$(swift build -c "$configuration" --show-bin-path)/MichelMails

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_path" "$app_dir/Contents/MacOS/MichelMails"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"

codesign --force --deep --sign - \
  --entitlements "$project_dir/Resources/MichelMails.entitlements" \
  "$app_dir"

echo "$app_dir"
