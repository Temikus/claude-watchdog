#!/usr/bin/env bash
# Generate a large transcript for the perf budget, rather than committing a
# multi-megabyte blob. Deterministic: same size and content every run.
#
#   bash tests/fixtures/gen-large-session.sh [out-path] [target-bytes]
#
# Defaults to tests/fixtures/large-session.jsonl at ~1 MB (gitignored).
# The shape mirrors a real turn - user ask, assistant text + Edit tool_use,
# tool_result - so the Stop hook's gates (tool uses, edits, user messages) all
# see realistic counts, and includes one thinking block and one MCP tool name
# per 50 rounds so the condenser's less common paths are exercised at size.
set -euo pipefail

out="${1:-tests/fixtures/large-session.jsonl}"
target="${2:-1048576}"

mkdir -p "$(dirname "$out")"
awk -v target="$target" 'BEGIN {
  pad = ""
  for (i = 0; i < 160; i++) pad = pad "x"
  bytes = 0
  i = 0
  while (bytes < target) {
    i++
    lines[1] = sprintf("{\"type\":\"user\",\"uuid\":\"u-lg-%06d\",\"message\":{\"content\":\"round %d ask %s\"}}", i, i, pad)
    if (i % 50 == 0) {
      lines[2] = sprintf("{\"type\":\"assistant\",\"uuid\":\"a-lg-%06d\",\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"round %d reasoning %s\"},{\"type\":\"tool_use\",\"id\":\"toolu_lg%06d\",\"name\":\"mcp__github__create_issue\",\"input\":{\"title\":\"round %d\"}}]}}", i, i, pad, i, i)
    } else {
      lines[2] = sprintf("{\"type\":\"assistant\",\"uuid\":\"a-lg-%06d\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"round %d reply %s\"},{\"type\":\"tool_use\",\"id\":\"toolu_lg%06d\",\"name\":\"Edit\",\"input\":{\"file_path\":\"/repo/src/mod%d.py\",\"old_string\":\"a\",\"new_string\":\"b\"}}]}}", i, i, pad, i, i % 40)
    }
    lines[3] = sprintf("{\"type\":\"user\",\"uuid\":\"r-lg-%06d\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_lg%06d\",\"content\":\"round %d result %s\"}]}}", i, i, i, pad)
    for (k = 1; k <= 3; k++) { print lines[k]; bytes += length(lines[k]) + 1 }
  }
}' > "$out"

size=$(wc -c < "$out" | tr -d ' ')
[ "$size" -ge "$target" ] || { echo "generated ${size} B, expected at least ${target} B" >&2; exit 1; }
echo "$out: ${size} bytes"
