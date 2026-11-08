#!/usr/bin/env python3
"""Change property values in a build.prop of the SlimBOX image, in the file that defines them.

usage: edit_props.py <build.prop> <changes> <out> [NAME=value ...]

<changes> holds "key=value" lines (comments with #). Every key must already be defined exactly
once in <build.prop>: the line is changed in place, nothing is appended, so a property has one
definition and no load-order tricks decide its value. @NAME@ in a value is replaced from the
NAME=value arguments (all of them must be used).
"""
import re
import sys


def main():
    src, changes, out = sys.argv[1:4]
    subst = dict(a.split("=", 1) for a in sys.argv[4:])
    used = set()

    def fill(m):
        used.add(m.group(1))
        return subst[m.group(1)]

    want = {}
    for n, line in enumerate(open(changes, encoding="utf-8"), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, val = line.split("=", 1)
        if key in want:
            sys.exit(f"{changes}:{n}: {key} given twice")
        want[key] = re.sub(r"@([A-Z]+)@", fill, val)
    if used != set(subst):
        sys.exit(f"unused substitutions: {sorted(set(subst) - used)}")

    lines = open(src, encoding="utf-8").read().split("\n")
    found = {k: [] for k in want}
    for i, line in enumerate(lines):
        key = line.split("=", 1)[0].strip()
        if not line.lstrip().startswith("#") and "=" in line and key in want:
            found[key].append(i)
    for key, idx in found.items():
        if len(idx) != 1:
            sys.exit(f"{src}: {key} defined {len(idx)} times, expected once")
        old = lines[idx[0]].split("=", 1)[1]
        lines[idx[0]] = f"{key}={want[key]}"
        print(f"{key}: {old} -> {want[key]}")
    open(out, "w", encoding="utf-8").write("\n".join(lines))


if __name__ == "__main__":
    main()
