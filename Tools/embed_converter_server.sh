#!/bin/sh
set -eu

server_source="${BUILT_PRODUCTS_DIR}/ConverterServer.app"
server_destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/ConverterServer.app"
mkdir -p "$(dirname "${server_destination}")"
ditto "${server_source}" "${server_destination}"
