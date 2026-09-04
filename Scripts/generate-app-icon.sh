#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
build_dir="$project_dir/.build"
source_png="$build_dir/MichelMails-1024.png"
iconset_dir="$build_dir/MichelMails.iconset"
output_icns="$project_dir/Resources/MichelMails.icns"

mkdir -p "$build_dir"
rm -rf "$iconset_dir"
mkdir -p "$iconset_dir"

swift "$project_dir/Scripts/generate-app-icon.swift" "$source_png"

for specification in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    size="${specification%% *}"
    filename="${specification#* }"
    sips -z "$size" "$size" "$source_png" --out "$iconset_dir/$filename" >/dev/null
done

iconutil -c icns "$iconset_dir" -o "$output_icns"
echo "$output_icns"
