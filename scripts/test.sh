#!/bin/sh
# Runs the test suite, optimized because the AutoEQ fitter is very slow unoptimized.
# With only the Command Line Tools installed (no Xcode), Swift Testing isn't on the
# default search paths, so point the build at it.
set -e
cd "$(dirname "$0")/.."

DEV=/Library/Developer/CommandLineTools/Library/Developer
if [ -d "$DEV/Frameworks/Testing.framework" ]; then
  exec swift test -Xswiftc -O \
    -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
    -Xlinker -F -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
    "$@"
fi
exec swift test -Xswiftc -O "$@"
