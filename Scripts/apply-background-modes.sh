#!/bin/sh -e

#  apply-background-modes.sh
#  Loop
#
#  Copyright © 2026 LoopKit Authors. All rights reserved.

# Adds or removes optional UIBackgroundModes in the built Info.plist. iOS reads
# background modes only from the app's own Info.plist, so plugins cannot declare
# them.
#
# LOOP_BLUETOOTH_PERIPHERAL_BACKGROUND_MODE (Loop.xcconfig, default YES) adds
# bluetooth-peripheral, which watch plugins that publish a Bluetooth service, such
# as the Luped Pebble link, need to keep the watch updated while Loop is in the
# background. Set it to NO in LoopConfigOverride.xcconfig to leave the mode out.

SCRIPT="$(basename "${0}")"

error() {
  echo "ERROR: ${*}" >&2
  echo "Usage: ${SCRIPT} [-i|--info-plist-path info-plist-path]" >&2
  echo "Parameters:" >&2
  echo "  -i|--info-plist-path <info-plist-path>                     path to the Info.plist file to modify; optional, defaults to \${TARGET_BUILD_DIR}/\${INFOPLIST_PATH}" >&2
  exit 1
}

info() {
  echo "INFO: ${*}" >&2
}

info_plist_path="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
while [[ $# -gt 0 ]]
do
  case $1 in
    -i|--info-plist-path)
      info_plist_path="${2}"
      shift 2
      ;;
    *)
      error "Unexpected argument: ${1}"
      ;;
  esac
done

if [ "${info_plist_path}" == "/" -o ! -e "${info_plist_path}" ]; then
  error "Must provide valid --info-plist-path, or have valid \${TARGET_BUILD_DIR} and \${INFOPLIST_PATH} set."
fi

# Index of a background mode in UIBackgroundModes, or nothing if it is absent.
mode_index() {
  /usr/libexec/PlistBuddy -c "Print :UIBackgroundModes" "${info_plist_path}" 2>/dev/null \
    | sed -e '1d' -e '$d' -e 's/^ *//' \
    | grep -n -x "${1}" \
    | head -1 \
    | cut -d: -f1 \
    | awk '{ print $1 - 1 }'
}

mode="bluetooth-peripheral"
index="$(mode_index "${mode}")"
if [ "${LOOP_BLUETOOTH_PERIPHERAL_BACKGROUND_MODE}" = "YES" ]; then
  if [ -z "${index}" ]; then
    info "Adding background mode ${mode} (LOOP_BLUETOOTH_PERIPHERAL_BACKGROUND_MODE = YES)"
    /usr/libexec/PlistBuddy -c "Add :UIBackgroundModes: string ${mode}" "${info_plist_path}"
  fi
elif [ -n "${index}" ]; then
  info "Removing background mode ${mode} (LOOP_BLUETOOTH_PERIPHERAL_BACKGROUND_MODE = ${LOOP_BLUETOOTH_PERIPHERAL_BACKGROUND_MODE:-unset})"
  /usr/libexec/PlistBuddy -c "Delete :UIBackgroundModes:${index}" "${info_plist_path}"
fi
