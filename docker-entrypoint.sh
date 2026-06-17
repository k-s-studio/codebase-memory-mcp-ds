#!/bin/sh
# Entrypoint for the UI-enabled codebase-memory-mcp container.
#
# Two facts about the binary drive this script:
#   1. With --ui=true it serves the 3D graph UI as a thread *inside* the normal
#      "MCP server on stdio" process. That process reads stdin and exits on EOF —
#      so to keep the UI alive we must feed it a stdin that never closes
#      (`tail -f /dev/null | ...`).
#   2. The UI HTTP server binds 127.0.0.1 only (there is no --host flag), so a
#      plain `docker -p 9749:9749` publish can't reach it. We run the UI on an
#      internal loopback port and use socat to expose it on 0.0.0.0.
set -e

UI_PORT_INTERNAL="${CBM_UI_PORT_INTERNAL:-9750}"   # loopback-only, where the UI actually listens
PUBLISH_PORT="${CBM_PUBLISH_PORT:-9749}"           # 0.0.0.0, what the host maps to

# Start the UI server with a stdin that never hits EOF, so it stays resident.
tail -f /dev/null | codebase-memory-mcp --ui=true --port="$UI_PORT_INTERNAL" &

# Forward host-reachable 0.0.0.0:PUBLISH_PORT -> loopback UI. socat is PID 1
# (via exec): if the forwarder dies the container stops, which is the signal we want.
exec socat TCP-LISTEN:"$PUBLISH_PORT",fork,reuseaddr TCP:127.0.0.1:"$UI_PORT_INTERNAL"
