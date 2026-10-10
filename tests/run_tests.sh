#!/usr/bin/env bash
# Runs the Lua tests with Kahlua from the game's own jar.
#   PZ_DIR    Project Zomboid install folder (default below)
#   JAVAC     a JDK 17+ javac, only used to compile the small test runner
set -e

# pwd -W gives a Windows path under Git Bash, which the Windows java needs.
ROOT="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
PZ_DIR="${PZ_DIR:-D:/Games/Steam/steamapps/common/ProjectZomboid}"
JAVAC="${JAVAC:-javac}"

mkdir -p "$ROOT/build"
"$JAVAC" -d "$ROOT/build" "$ROOT/tests/KahluaRunner.java"

# Kahlua loads stdlib.lua from the working directory, so run from the game folder.
cd "$PZ_DIR"
./jre64/bin/java -Droot="$ROOT" -cp "$ROOT/build;projectzomboid.jar" KahluaRunner \
    "$ROOT/tests/test_core.lua" \
    "$ROOT/tests/test_server.lua" \
    "$ROOT/tests/test_client.lua"
