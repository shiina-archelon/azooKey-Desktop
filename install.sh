#!/bin/bash
set -xe -o pipefail

IGNORE_LINT=false
DRY_RUN=false
NO_PKILL=false
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
# 純正 azooKey (/Library/Input Methods/azooKeyMac.app) と併存させるため別名で設置する。
# bundle ID も別なので、入力ソース一覧に 2 つ並んで切り替えられる。
INSTALL_APP_PATH="/Library/Input Methods/azooKeyForkMac.app"

# Parse command-line options
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ignore-lint) IGNORE_LINT=true ;;
        --dry-run) DRY_RUN=true ;;
        --no-pkill) NO_PKILL=true ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [ "$IGNORE_LINT" = false ]; then
    if command -v swiftlint &> /dev/null
    then
        # Fix auto-fixable errors
        swiftlint --fix --format
        # Check other errors
        swiftlint --quiet --strict
    else
        echo "swiftlint could not be found. Please rerun the script as \`./install.sh --ignore-lint\`."
        echo "For contributing azooKey on macOS, we strongly recommend you to install swiftlint"
        echo "To install swiftlint, run \`brew install swiftlint\`"
        exit 1
    fi
else
    echo "Skipping swiftlint checks due to --ignore-lint option."
fi


BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/archive.xcarchive"
STAGING_DIR="$BUILD_DIR/.install-build"
STAGED_ARCHIVE="$STAGING_DIR/archive.xcarchive"
PREVIOUS_ARCHIVE="$STAGING_DIR/previous.xcarchive"

mkdir -p "$BUILD_DIR"
if ! mkdir "$STAGING_DIR"; then
    printf '別のビルドが実行中か、中断したビルドの作業領域が残っています。場所 %s\n' "$STAGING_DIR" >&2
    exit 1
fi

cleanup_archive() {
    if [[ -d "$PREVIOUS_ARCHIVE" && ! -e "$ARCHIVE_PATH" ]]; then
        if ! mv "$PREVIOUS_ARCHIVE" "$ARCHIVE_PATH"; then
            printf '直前のアーカイブを %s に保持しています。\n' "$PREVIOUS_ARCHIVE" >&2
            return 1
        fi
    fi
    rm -rf "$STAGING_DIR"
}
trap cleanup_archive EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ARCHIVE_COMMAND=(xcodebuild -project azooKeyMac.xcodeproj -scheme azooKeyMac clean archive -archivePath "$STAGED_ARCHIVE" -allowProvisioningUpdates)
if command -v xcpretty &> /dev/null; then
    "${ARCHIVE_COMMAND[@]}" | xcpretty
else
    echo "xcpretty could not be found. Proceeding without xcpretty."
    "${ARCHIVE_COMMAND[@]}"
fi

if [[ ! -d "$STAGED_ARCHIVE/Products/Applications/azooKeyMac.app" ]]; then
    printf 'アーカイブに azooKeyMac.app がありません。場所 %s\n' "$STAGED_ARCHIVE" >&2
    exit 1
fi
if [[ -e "$ARCHIVE_PATH" || -L "$ARCHIVE_PATH" ]]; then
    mv "$ARCHIVE_PATH" "$PREVIOUS_ARCHIVE"
fi
mv "$STAGED_ARCHIVE" "$ARCHIVE_PATH"
rm -rf "$PREVIOUS_ARCHIVE"

ARCHIVED_APP="build/archive.xcarchive/Products/Applications/azooKeyMac.app"

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Would execute the following commands:"
    echo "  sudo ${REPO_ROOT}/Tools/remove_converter_server_launch_agent.sh"
    printf '  sudo rm -rf %q\n' "$INSTALL_APP_PATH"
    printf '  sudo ditto %q %q\n' "$ARCHIVED_APP" "$INSTALL_APP_PATH"
    if [ "$NO_PKILL" = false ]; then
        echo "  pkill azooKeyMac || true"
    fi
    echo "Build completed successfully. Use without --dry-run to actually install."
else
    sudo "${REPO_ROOT}/Tools/remove_converter_server_launch_agent.sh"
    sudo rm -rf "$INSTALL_APP_PATH"
    # Preserve the symlinks in versioned frameworks so their signatures remain valid.
    sudo ditto "$ARCHIVED_APP" "$INSTALL_APP_PATH"
    if [ "$NO_PKILL" = false ]; then
        pkill azooKeyMac || true
    fi
fi
