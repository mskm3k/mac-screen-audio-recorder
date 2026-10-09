# Build from source（macOS）

**対象:** macOS 14.2以上 / Apple SiliconまたはIntel。macOS SDKとSwiftコンパイラ（Xcodeまたは対応する開発ツール）が必要です。

この公開用ソースには開発者固有のビルド・署名スクリプトを含めていません。以下はユーザーのMac上でソースから組み立てるための**参考手順**です。AppleのDeveloper ID署名・公証済みの配布物を作成する手順ではありません。

ターミナルで、このリポジトリのルートへ移動してから、以下のコマンドを実行してください。スペースを含むパスにも対応します。macOSの標準ターミナル（zsh）でも、`bash` 内でコマンドを実行します。

```bash
bash <<'BUILD_MSAR'
set -euo pipefail
ROOT="$PWD"
APP="$HOME/Desktop/Mac Screen Audio Recorder Build/Mac Screen Audio Recorder.app"
TMP="$(mktemp -d)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP/AppIcon.iconset"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# アイコンを生成
for spec in '16 16x16' '32 16x16@2x' '32 32x32' '64 32x32@2x' '128 128x128' '256 128x128@2x' '256 256x256' '512 256x256@2x' '512 512x512'; do
  IFS=' ' read -r dim icon_name <<< "$spec"
  sips -z "$dim" "$dim" "$ROOT/Resources/AppIcon-1024.png" --out "$TMP/AppIcon.iconset/icon_$icon_name.png" >/dev/null
done
cp "$ROOT/Resources/AppIcon-1024.png" "$TMP/AppIcon.iconset/icon_512x512@2x.png"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

COMMON=(
  -swift-version 5 -O -whole-module-optimization -sdk "$SDK"
  -framework AppKit -framework ScreenCaptureKit -framework AVFoundation
  -framework CoreMedia -framework CoreVideo -framework CoreGraphics -framework AudioToolbox
  "$ROOT/Sources/RecorderEngine.swift"
  "$ROOT/Sources/RegionSelector.swift"
  "$ROOT/Sources/main.swift"
)
xcrun --sdk macosx swiftc "${COMMON[@]}" -target arm64-apple-macosx14.2 -o "$TMP/arm64"
xcrun --sdk macosx swiftc "${COMMON[@]}" -target x86_64-apple-macosx14.2 -o "$TMP/x86_64"
xcrun lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/MacScreenAudioRecorder"
chmod +x "$APP/Contents/MacOS/MacScreenAudioRecorder"
xcrun lipo -info "$APP/Contents/MacOS/MacScreenAudioRecorder"

# ローカル用のアドホック署名。Developer ID署名・Apple公証ではありません。
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"
rm -rf "$TMP"
echo "Build complete: $APP"
BUILD_MSAR
```

**既に同名のアプリがある場合は必要なバックアップを取ってから実行してください。** この手順は同じ出力先を使用します。

生成場所は `~/Desktop/Mac Screen Audio Recorder Build/Mac Screen Audio Recorder.app` です。ローカルで生成したアプリはDeveloper ID署名・公証済みの一般配布アプリではありません。macOSのセキュリティ制限や画面収録の許可が必要になる場合があります。アドホック署名では更新時に権限の再許可が必要になる場合があります。

**検証状況（2026-10-10）:** v1.0.2の公開用ソースとこの公開専用ビルド手順を使用してMac実機でビルド・アプリ起動・画面録画・システム音声録音を確認済みです。さらに画面収録の許可を取り消した状態から、macOS標準の許可要求表示・設定ON・録画と音声の確認も実施済みです。
