#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"
DATASET_FILE="$BENCH_DIR/cache/swebench/swe-bench-lite.jsonl"
OUT_DIR="$BENCH_DIR/tests/swebench"

require_dataset() {
  [[ -f "$DATASET_FILE" ]] && return
  echo "Missing dataset file: $DATASET_FILE" >&2
  echo "Run a swebench command once to download dataset." >&2
  exit 1
}

write_lists() {
  python3 - "$DATASET_FILE" "$OUT_DIR" <<'PY'
import collections, json, os, sys
src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
items=[(json.loads(l)['instance_id'], json.loads(l)['repo']) for l in open(src)]
open(f"{out}/all-instances.md","w").write("# SWE-bench Lite instance IDs (dataset order)\n\n" + "\n".join(i for i,_ in items) + "\n")
by=collections.OrderedDict()
for iid,repo in items: by.setdefault(repo,[]).append(iid)
rr=[]; i=0
while True:
    row=[ids[i] for ids in by.values() if i < len(ids)]
    if not row: break
    rr.extend(row); i+=1
open(f"{out}/round-robin-by-repo.md","w").write("# SWE-bench Lite instance IDs (balanced round-robin by repo)\n\n" + "\n".join(rr) + "\n")
print(f"Wrote {len(items)} IDs to all-instances.md and round-robin-by-repo.md")
PY
}

main() {
  require_dataset
  write_lists
}

main "$@"
