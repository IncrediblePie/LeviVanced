#!/usr/bin/env python3
"""
Compare two locale JSON files and report mutual differences.

Features:
- Flattens nested keys into dot-separated paths for both files.
- Reports keys missing in B compared to A, and missing in A compared to B.
- Detects placeholder mismatches (e.g., {{name}}) on common string keys.
- Optional prefix ignores to skip specific namespaces.

Usage:
  python scripts/compare_locale_json.py \
    --a frontend/src/assets/locales/en_US.json \
    --b frontend/src/assets/locales/zh_CN.json \
    --output locale_diff.json \
    --ignore-prefix launcherpage.header --ignore-prefix mcpathform

Notes:
- Only leaf values are considered (string/number/bool/null). Objects/lists are expanded.
- For lists, numeric indices are appended in key paths.
"""

import argparse
import json
import os
import re
import sys
from typing import Dict, Iterable, List, Tuple


def load_json(path: str) -> Dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def flatten_map(data: object, prefix: str = "") -> Dict[str, object]:
    """Flatten nested dict/list into a mapping of dot-separated paths -> leaf values."""
    acc: Dict[str, object] = {}
    if isinstance(data, dict):
        for k, v in data.items():
            pfx = f"{prefix}.{k}" if prefix else k
            if isinstance(v, (dict, list)):
                acc.update(flatten_map(v, pfx))
            else:
                acc[pfx] = v
    elif isinstance(data, list):
        for i, v in enumerate(data):
            pfx = f"{prefix}.{i}" if prefix else str(i)
            if isinstance(v, (dict, list)):
                acc.update(flatten_map(v, pfx))
            else:
                acc[pfx] = v
    return acc


def filter_prefixes(keys: Iterable[str], prefixes: List[str]) -> List[str]:
    if not prefixes:
        return list(keys)
    out = []
    for k in keys:
        if any(k.startswith(p) for p in prefixes):
            continue
        out.append(k)
    return out


PLACEHOLDER_RE = re.compile(r"\{\{\s*([a-zA-Z0-9_]+)\s*\}\}")


def extract_placeholders(val: object) -> List[str]:
    if not isinstance(val, str):
        return []
    return sorted(set(m.group(1) for m in PLACEHOLDER_RE.finditer(val)))


def compare_locales(a_map: Dict[str, object], b_map: Dict[str, object], ignore_prefixes: List[str]):
    a_keys = set(filter_prefixes(a_map.keys(), ignore_prefixes))
    b_keys = set(filter_prefixes(b_map.keys(), ignore_prefixes))

    missing_in_b = sorted(a_keys - b_keys)
    missing_in_a = sorted(b_keys - a_keys)

    common = sorted(a_keys & b_keys)
    placeholder_mismatch = []
    for k in common:
        a_ph = extract_placeholders(a_map.get(k))
        b_ph = extract_placeholders(b_map.get(k))
        if a_ph != b_ph:
            placeholder_mismatch.append({
                "key": k,
                "a_placeholders": a_ph,
                "b_placeholders": b_ph,
            })

    return {
        "a_keys_count": len(a_keys),
        "b_keys_count": len(b_keys),
        "missing_in_b": missing_in_b,
        "missing_in_a": missing_in_a,
        "common_keys": len(common),
        "placeholder_mismatch": placeholder_mismatch,
    }


def main():
    parser = argparse.ArgumentParser(description="Compare two locale JSON files for missing keys and placeholder mismatches.")
    parser.add_argument("--a", default="../frontend/src/assets/locales/en_US.json", help="Path to locale A (reference)")
    parser.add_argument("--b", default="../frontend/src/assets/locales/zh_CN.json", help="Path to locale B (to compare against A)")
    parser.add_argument("--output", default="locale_diff.json", help="Output JSON path for the diff report")
    parser.add_argument("--ignore-prefix", action="append", default=[], help="Ignore keys starting with this prefix (repeatable)")
    args = parser.parse_args()

    print(f"[info] A: {args.a}")
    print(f"[info] B: {args.b}")
    if args.ignore_prefix:
        print(f"[info] ignoring prefixes: {', '.join(args.ignore_prefix)}")

    try:
        a_data = load_json(args.a)
        b_data = load_json(args.b)
    except Exception as e:
        print(f"[error] failed to load locales: {e}", file=sys.stderr)
        sys.exit(1)

    a_map = flatten_map(a_data)
    b_map = flatten_map(b_data)

    report = {
        "a_file": args.a,
        "b_file": args.b,
    }
    report.update(compare_locales(a_map, b_map, args.ignore_prefix))

    # Console summary
    print(f"[summary] keys A: {report['a_keys_count']} | keys B: {report['b_keys_count']} | common: {report['common_keys']}")
    print(f"[summary] missing in B compared to A: {len(report['missing_in_b'])}")
    print(f"[summary] missing in A compared to B: {len(report['missing_in_a'])}")
    if report["placeholder_mismatch"]:
        print(f"[summary] placeholder mismatches: {len(report['placeholder_mismatch'])}")

    # Write JSON file
    try:
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2, ensure_ascii=False)
        print(f"[ok] diff report written to {args.output}")
    except Exception as e:
        print(f"[error] failed to write diff report {args.output}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()