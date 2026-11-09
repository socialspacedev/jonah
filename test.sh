#!/bin/bash
#
# Run Jonah's tests.
#
# With only the Command Line Tools installed, Swift Testing isn't on the default
# search path, and its Foundation overlay is missing, so point at it by hand.
# With full Xcode, plain `swift test` works too.
#
set -euo pipefail
cd "$(dirname "$0")"

DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
if [ -d "$FW/Testing.framework" ]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$FW" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -rpath -Xlinker "$FW" \
        "$@"
fi
exec swift test "$@"
