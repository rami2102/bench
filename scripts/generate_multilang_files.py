#!/usr/bin/env python3
"""Generate round-robin test list and dataset summary from Multi-SWE-bench_mini."""

import json
from collections import defaultdict

JSONL_PATH = "cache/multilang/multi-swe-bench-mini.jsonl"
ROUND_ROBIN_PATH = "tests/multilang/round-robin-by-language.md"
SUMMARY_PATH = "tests/multilang/dataset-summary.json"

LANG_ORDER = ["python", "js", "ts", "java", "c++", "go", "rust", "c"]
DIFF_ORDER = {"easy": 0, "medium": 1, "hard": 2}

with open(JSONL_PATH) as f:
    data = [json.loads(line) for line in f]

# Group by language, sort each group by difficulty then instance_id
by_lang = defaultdict(list)
for d in data:
    by_lang[d["language"]].append(d)

for lang in by_lang:
    by_lang[lang].sort(key=lambda d: (DIFF_ORDER.get(d["difficulty"], 99), d["instance_id"]))

# Round-robin
rr_lines = []
max_per_lang = max(len(by_lang[l]) for l in LANG_ORDER)
for i in range(max_per_lang):
    for lang in LANG_ORDER:
        if i < len(by_lang[lang]):
            rr_lines.append(by_lang[lang][i]["instance_id"])

# Write round-robin file
with open(ROUND_ROBIN_PATH, "w") as f:
    f.write("# Round-robin test instances by language\n")
    f.write("# Order: python, javascript (js), typescript (ts), java, c++, go, rust, c\n")
    f.write("# Within each language, ordered by difficulty: easy, medium, hard\n")
    f.write("# Every 8 consecutive lines cover all 8 languages\n")
    f.write(f"# Total instances: {len(rr_lines)}\n")
    for iid in rr_lines:
        f.write(f"{iid}\n")

# Build summary
per_lang_counts = {}
per_lang_repos = {}
for lang in LANG_ORDER:
    items = by_lang[lang]
    per_lang_counts[lang] = len(items)
    per_lang_repos[lang] = sorted(set(d["repo"] for d in items))

diff_counts = defaultdict(int)
for d in data:
    diff_counts[d["difficulty"]] += 1

unique_repos = {}
for d in data:
    key = f"{d['org']}/{d['repo']}"
    if key not in unique_repos:
        unique_repos[key] = {"repo": d["repo"], "org": d["org"], "language": d["language"]}

summary = {
    "total_instances": len(data),
    "per_language_counts": per_lang_counts,
    "per_language_repos": per_lang_repos,
    "per_difficulty_counts": dict(sorted(diff_counts.items(), key=lambda x: DIFF_ORDER.get(x[0], 99))),
    "unique_repos": sorted(unique_repos.values(), key=lambda r: (r["language"], r["org"], r["repo"]))
}

with open(SUMMARY_PATH, "w") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")

print(f"Written {ROUND_ROBIN_PATH} ({len(rr_lines)} instances)")
print(f"Written {SUMMARY_PATH}")
