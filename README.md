# Mac Screen Audio Recorder

**v1.0.2 / Build 16** · © 2026 msk  
**macOS 14.2以降 / macOS 14.2 or later**

Macの画面映像とシステム音声を同時に録画する、macOSネイティブアプリです。外部の仮想オーディオドライバを必要としません。

**This source package contains no prebuilt, Developer ID–signed, or notarized application.**

## 主な機能 / Features

- 全画面・指定ウィンドウ・ドラッグで調整できる指定範囲の録画
- ScreenCaptureKitによるシステム音声の録音（BlackHole等は不要）
- MOVファイル保存（H.264映像 + AAC音声）
- 本体画面またはメニューバーから録画開始・停止
- 録画範囲の位置・サイズを記憶
- Apple Silicon（arm64）・Intel（x86_64）に対応するUniversal 2ビルド

## v1.0.2での変更

macOSの画面収録許可ダイアログとアプリ独自のモーダル警告が重ならないよう修正。許可未取得時はアプリ画面の状態表示で案内します。既存の録画・録音処理やアイコン、基本UIは変更していません。

## ビルド / Build from source

[BUILD_FROM_SOURCE.md](BUILD_FROM_SOURCE.md) を参照してください。Macと対応するAppleの開発ツールが必要です。ビルド後のアプリはローカル用アドホック署名であり、Apple公証済み配布物ではありません。

- v1.0.2のMac実機ビルド・画面録画・システム音声録音は、開発版のビルド手順で確認済みです。
- この公開専用 `BUILD_FROM_SOURCE.md` を使用したv1.0.2のMac実機ビルド・起動・画面録画・システム音声録音・権限を取り消した状態からの許可要求表示を確認済みです。利用環境のXcode・SDKにより動作が異なる場合があります。

## 使用方法 / Usage

1. 初回録画時はmacOSの「画面とシステムオーディオ録音」を許可します。許可変更後はアプリを再起動してください。
2. 「全画面」「ウィンドウ」「範囲指定」を選択します。ウィンドウと範囲は録画開始前に設定します。
3. RECで録画を開始し、STOPで終了します。MOV保存完了まで待ってください。

## 既知の制限 / Known limitations

- 指定ウィンドウ録画では、録画開始時のウィンドウ矩形を録画します。録画中の移動・リサイズには追従しません。
- 対象矩形の外にはみ出したメニュー部分は録画されません。別のウィンドウが対象部分に重なると映り込むことがあります。
- 外部マイクの収録機能はありません。
- OS更新・権限・音声出力方式によって動作が変わる場合があります。

## 利用条件 / License

これは **source-available（ソース公開型）** ソフトウェアです。OSI承認のオープンソースライセンスではありません。

- ソースやビルド済みアプリの無償利用・改造・無償配布を許可します。
- ソース・完成アプリ・改造版の販売や有償提供は禁止します（著作権者の事前書面許可がある場合を除く）。
- **アプリを仕事で使うこと、録画・録音した動画や音声を販売・公開・配信・収益化することは自由です。**
- msk名・ロゴ・アプリアイコンは別条件です。改変版を配布する際は別の名前とアイコンを使ってください。

詳細は [LICENSE.txt](LICENSE.txt) と [BRANDING.md](BRANDING.md) を確認してください。両文書の利用条件は著作権者により承認されています。

No warranty, personal technical support, or continued maintenance is promised. See [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) for dependencies and distribution notices. This is not an Apple product.
