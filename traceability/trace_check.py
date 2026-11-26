#!/usr/bin/env python3
# ===========================================================================
# FSAC - Flight Stability Augmentation Computer
# ===========================================================================
# File        : traceability/trace_check.py
# Module      : Requirement trace checker
# Language    : Python 3.8 or newer, standard library only
# Assurance   : Review aid, not part of the delivered software. It is NOT a
#               qualified tool (no DO-330 claim): its output must be read, not
#               trusted.
# Requirements: SECR-PLAN-0001, SECR-PLAN-0003 (placeholder IDs)
#
# PURPOSE
#   Reads the repository and answers four questions about requirement IDs:
#     1. Which IDs are cited, and by what kind of file?
#     2. Which IDs are DEFINED (have a statement in docs/03_requirements)?
#     3. Which links in traceability/*.links point at something that exists?
#     4. Which IDs have implementation, test or proof evidence linked to them?
#   It checks LINKS, not RESULTS. It does not know whether a test passed. A row
#   that shows "tested" means a test file cites the ID or a link names a test,
#   nothing more (PSecAC, section 5.2: written is not tested).
#
# DESIGN RULES
#   R1  Standard library only, ASCII output, no network, no writes except the
#       optional --csv file.
#   R2  The first token of an ID is its level (docs/03_requirements/
#       requirements_index.md, rule I-7). HLR-SYS-0001 is level HLR, area SYS.
#   R3  A range "A .. B" is expanded into every ID between the two ends. The
#       second end may be written in full or as four digits. Ranges that differ
#       in level or area, run backwards, or exceed 200 IDs are errors.
#   R4  A DEFINITION is the first cell of a markdown table row in a file under
#       docs/03_requirements/. Tables whose header row contains the word
#       "proposed" are ignored: a proposal is not a definition.
#   R5  Files are classified by path: "def" (docs/03_requirements), "test"
#       (a tests folder, or a name starting with test_), "doc" (other files
#       under docs, or a markdown or text file anywhere), "impl" (everything
#       else). The traceability/ folder itself is never scanned for citations,
#       so this banner does not cite anything.
#   R6  Deterministic output: files and IDs are visited in sorted order.
#
# WHAT IT REPORTS
#   Errors (the exit code is 1):
#     E-RANGE       malformed range
#     E-DUP         an ID defined in more than one place
#     E-LINKFMT     malformed line in a .links file
#     E-LINKPATH    a link target file does not exist or is outside the repo
#     E-LINKANCHOR  a link anchor text is not found in its target file
#   Warnings (the exit code stays 0 unless --strict):
#     W-UNDEF       cited or linked, but not defined
#     W-ORPHAN      defined, but cited and linked by nothing
#     W-NOTEST      defined and implemented, but no test, proof or review link
#
# LINK FILE FORMAT (traceability/*.links)
#   One link per line, three fields separated by a vertical bar:
#       IDs | kind | target
#   IDs     one ID or a range, for example  HLR-CTL-0013 .. HLR-CTL-0019
#   kind    impl, test, proof, review, analysis or inspection
#   target  a path from the repository root, optionally followed by #anchor;
#           the anchor is text that must appear in the file, for example a
#           test group label:  software/hal_c/tests/test_secure_boot.c#D-04
#   Lines that are empty or start with # are comments.
#
# USAGE (from the repository root)
#   python traceability/trace_check.py
#   python traceability/trace_check.py --list undefined
#   python traceability/trace_check.py --list all --strict
#   python traceability/trace_check.py --csv traceability/trace_matrix.csv
#   --root PATH  scan another folder (default: the folder above this script)
#   On Windows Git Bash use "python" or "py" if "python3" is not found.
#
# WHAT THIS DOES NOT COVER
#   Whether a statement is correct, whether a test passed, whether a link is
#   RELEVANT (only that it resolves), and any requirement written in a form the
#   ID pattern does not match.
# ===========================================================================

import argparse
import csv
import os
import re
import sys
from pathlib import Path


MAX_RANGE = 200
MAX_BYTES = 2000000

SKIP_DIRS = {"build", "__pycache__", "node_modules", "traceability", "alire", "obj"}
EXTS = {".ads", ".adb", ".adc", ".gpr", ".c", ".h", ".py", ".md", ".txt",
        ".yaml", ".yml", ".toml", ".sh", ".vhd", ".vhdl", ".v"}
KINDS = ("impl", "test", "proof", "review", "analysis", "inspection")

ID_PAT = r"(?:SYS|HLR|LLR|SECR)-[A-Z][A-Z0-9]*-[0-9]{4}"
FILL = r"[\s*/#-]*"
RE_ID = re.compile(r"\b(" + ID_PAT + r")\b")
RE_RANGE = re.compile(
    r"\b(" + ID_PAT + r")" + FILL + r"\.\." + FILL + r"(" + ID_PAT + r"|[0-9]{4})\b"
)
RE_SEP_CELL = re.compile(r"^:?-+:?$")


# ---------------------------------------------------------------------------
# IDs
# ---------------------------------------------------------------------------

def parse_id(text):
    # "HLR-CTL-0013" -> ("HLR", "CTL", 13)
    level, area, num = text.split("-")
    return (level, area, int(num))


def fmt_id(t):
    return "%s-%s-%04d" % t


def find_citations(text):
    # returns (set of ID tuples, list of (position, message) for bad ranges)
    ids = set()
    errors = []
    spans = []

    for m in RE_RANGE.finditer(text):
        spans.append((m.start(), m.end()))
        first = parse_id(m.group(1))
        second_txt = m.group(2)
        if len(second_txt) == 4 and second_txt.isdigit():
            second = (first[0], first[1], int(second_txt))
        else:
            second = parse_id(second_txt)

        problem = None
        if (first[0], first[1]) != (second[0], second[1]):
            problem = "range ends differ in level or area"
        elif second[2] < first[2]:
            problem = "range ends in the wrong order"
        elif second[2] - first[2] > MAX_RANGE:
            problem = "range longer than %d" % MAX_RANGE

        if problem:
            errors.append((m.start(), "%s: %s .. %s" % (problem, m.group(1), second_txt)))
            ids.add(first)
            ids.add(second)
        else:
            for k in range(first[2], second[2] + 1):
                ids.add((first[0], first[1], k))

    for m in RE_ID.finditer(text):
        pos = m.start()
        inside = False
        for a, b in spans:
            if a <= pos < b:
                inside = True
                break
        if not inside:
            ids.add(parse_id(m.group(1)))

    return ids, errors


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


# ---------------------------------------------------------------------------
# files
# ---------------------------------------------------------------------------

def classify(rel):
    parts = rel.split("/")
    name = parts[-1]
    if len(parts) > 2 and parts[0] == "docs" and parts[1] == "03_requirements":
        return "def"
    if name.lower().endswith((".md", ".txt")) or parts[0] == "docs":
        return "doc"
    if "tests" in parts[:-1] or name.startswith("test_"):
        return "test"
    return "impl"


def iter_files(root):
    for dirpath, dirnames, filenames in os.walk(str(root)):
        dirnames[:] = sorted(d for d in dirnames
                             if d not in SKIP_DIRS and not d.startswith("."))
        for name in sorted(filenames):
            p = Path(dirpath) / name
            if p.suffix.lower() in EXTS:
                yield p


def read_text(path):
    return path.read_text(encoding="utf-8", errors="replace")


# ---------------------------------------------------------------------------
# definitions: first cell of a markdown table row
# ---------------------------------------------------------------------------

def read_definitions(text):
    found = []
    header = None
    in_table = False
    skip = False

    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s.startswith("|"):
            header = None
            in_table = False
            skip = False
            continue

        cells = [c.strip() for c in s.strip("|").split("|")]
        if all(RE_SEP_CELL.match(c) for c in cells):
            in_table = True
            skip = header is not None and any("proposed" in c.lower() for c in header)
            continue
        if not in_table:
            header = cells
            continue
        if skip:
            continue

        first = cells[0].strip("` ")
        if re.fullmatch(ID_PAT, first):
            found.append((parse_id(first), n))
    return found


# ---------------------------------------------------------------------------
# link files
# ---------------------------------------------------------------------------

def read_links(path, rel, root):
    links = []
    errors = []

    for n, raw in enumerate(read_text(path).splitlines(), 1):
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        where = "%s:%d" % (rel, n)

        parts = [p.strip() for p in s.split("|")]
        if len(parts) != 3:
            errors.append(("E-LINKFMT", where, "expected 'IDs | kind | target'"))
            continue

        ids, range_errors = find_citations(parts[0])
        for _pos, msg in range_errors:
            errors.append(("E-RANGE", where, msg))
        if not ids:
            errors.append(("E-LINKFMT", where, "no requirement ID in the first field"))
            continue

        kind = parts[1].lower()
        if kind not in KINDS:
            errors.append(("E-LINKFMT", where, "unknown kind '%s'" % parts[1]))
            continue

        target, _sep, anchor = parts[2].partition("#")
        target = target.strip()
        anchor = anchor.strip()
        tpath = root / target
        inside = True
        try:
            tpath.resolve().relative_to(root)
        except ValueError:
            inside = False
        if (not target) or (not inside) or (not tpath.is_file()):
            errors.append(("E-LINKPATH", where, "file not found or outside the repository: %s" % target))
            continue

        if anchor and anchor not in read_text(tpath):
            errors.append(("E-LINKANCHOR", where, "'%s' not found in %s" % (anchor, target)))
            continue

        links.append((ids, kind, target + ("#" + anchor if anchor else "")))
    return links, errors


# ---------------------------------------------------------------------------
# evidence helpers
# ---------------------------------------------------------------------------

def new_record():
    return {"def": [], "impl": set(), "test": set(), "doc": set(),
            "link": {k: set() for k in KINDS}}


def is_impl(d):
    return bool(d["impl"] or d["link"]["impl"])


def is_test(d):
    return bool(d["test"] or d["link"]["test"])


def is_proof(d):
    return bool(d["link"]["proof"])


def is_other(d):
    return bool(d["link"]["review"] or d["link"]["analysis"] or d["link"]["inspection"])


def is_cited(d):
    return bool(d["impl"] or d["test"] or d["doc"] or any(d["link"].values()))


def evidence_files(d, which):
    if which == "impl":
        return sorted(d["impl"] | d["link"]["impl"])
    if which == "test":
        return sorted(d["test"] | d["link"]["test"])
    if which == "doc":
        return sorted(d["doc"])
    if which == "proof":
        return sorted(d["link"]["proof"])
    return sorted(d["link"]["review"] | d["link"]["analysis"] | d["link"]["inspection"])


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def show(label, ids, info):
    print("%s (%d):" % (label, len(ids)))
    for i in ids:
        d = info[i]
        files = evidence_files(d, "impl") + evidence_files(d, "test") + evidence_files(d, "doc")
        sample = ", ".join(files[:3])
        if len(files) > 3:
            sample += ", ... (+%d)" % (len(files) - 3)
        print("  %s  %s" % (fmt_id(i), sample))


def main(argv=None):
    ap = argparse.ArgumentParser(description="FSAC requirement trace checker")
    ap.add_argument("--root", default=None, help="repository root (default: folder above this script)")
    ap.add_argument("--strict", action="store_true", help="warnings also fail the run")
    ap.add_argument("--list", action="append", default=[],
                    choices=["undefined", "orphan", "notest", "all"],
                    help="print the IDs behind a warning class")
    ap.add_argument("--csv", default=None, help="write one row per ID to this file")
    args = ap.parse_args(argv)

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parent.parent
    if not root.is_dir():
        print("trace_check: root is not a folder: %s" % root)
        return 2

    info = {}
    errors = []
    scanned = 0
    link_files = 0

    for p in iter_files(root):
        if p.stat().st_size > MAX_BYTES:
            continue
        rel = p.relative_to(root).as_posix()
        text = read_text(p)
        scanned += 1
        cls = classify(rel)

        if cls == "def":
            for i, line in read_definitions(text):
                info.setdefault(i, new_record())["def"].append((rel, line))
            continue

        ids, range_errors = find_citations(text)
        for pos, msg in range_errors:
            errors.append(("E-RANGE", "%s:%d" % (rel, line_of(text, pos)), msg))
        for i in ids:
            info.setdefault(i, new_record())[cls].add(rel)

    tdir = root / "traceability"
    if tdir.is_dir():
        for lp in sorted(tdir.rglob("*.links")):
            link_files += 1
            rel = lp.relative_to(root).as_posix()
            links, link_errors = read_links(lp, rel, root)
            errors.extend(link_errors)
            for ids, kind, target in links:
                for i in ids:
                    info.setdefault(i, new_record())["link"][kind].add(target)

    for i in sorted(info):
        defs = info[i]["def"]
        if len(defs) > 1:
            where = ", ".join("%s:%d" % (f, n) for f, n in defs)
            errors.append(("E-DUP", fmt_id(i), "defined %d times: %s" % (len(defs), where)))

    undefined = sorted(i for i, d in info.items() if not d["def"])
    orphan = sorted(i for i, d in info.items() if d["def"] and not is_cited(d))
    notest = sorted(i for i, d in info.items()
                    if d["def"] and is_impl(d) and not (is_test(d) or is_proof(d) or is_other(d)))

    # ---- report ----
    print("FSAC trace check")
    print("root: %s" % root)
    print("scanned %d files, %d link files, %d requirement IDs seen" % (scanned, link_files, len(info)))
    print("")

    areas = {}
    for i, d in info.items():
        key = "%s-%s" % (i[0], i[1])
        a = areas.setdefault(key, {"ids": 0, "defined": 0, "impl": 0, "test": 0, "proof": 0})
        a["ids"] += 1
        if d["def"]:
            a["defined"] += 1
        if is_impl(d):
            a["impl"] += 1
        if is_test(d):
            a["test"] += 1
        if is_proof(d):
            a["proof"] += 1

    print("%-12s %5s %8s %6s %7s %6s %10s" % ("area", "IDs", "defined", "impl", "tested", "proof", "undefined"))
    totals = {"ids": 0, "defined": 0, "impl": 0, "test": 0, "proof": 0}
    for key in sorted(areas):
        a = areas[key]
        print("%-12s %5d %8d %6d %7d %6d %10d" %
              (key, a["ids"], a["defined"], a["impl"], a["test"], a["proof"], a["ids"] - a["defined"]))
        for k in totals:
            totals[k] += a[k]
    print("%-12s %5d %8d %6d %7d %6d %10d" %
          ("TOTAL", totals["ids"], totals["defined"], totals["impl"], totals["test"],
           totals["proof"], totals["ids"] - totals["defined"]))
    print("")
    print("impl = cited by a source file or linked as impl; tested = cited by a test file or")
    print("linked as test; proof = linked as proof. These are LINKS, not results.")
    print("A header that cites a RANGE counts every ID in it, so 'tested' can overstate coverage;")
    print("only link files with anchors say WHICH test covers WHICH requirement.")
    print("")

    print("Errors: %d" % len(errors))
    for code, where, msg in errors:
        print("  %-13s %s  %s" % (code, where, msg))
    print("Warnings: W-UNDEF %d, W-ORPHAN %d, W-NOTEST %d" % (len(undefined), len(orphan), len(notest)))
    print("")

    wanted = set(args.list)
    if "all" in wanted:
        wanted = {"undefined", "orphan", "notest"}
    if "undefined" in wanted:
        show("W-UNDEF cited or linked but not defined", undefined, info)
    if "orphan" in wanted:
        show("W-ORPHAN defined but cited by nothing", orphan, info)
    if "notest" in wanted:
        show("W-NOTEST defined and implemented, no test/proof/review link", notest, info)

    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["id", "defined", "definition", "impl", "test", "doc", "proof", "other", "links"])
            for i in sorted(info):
                d = info[i]
                definition = "%s:%d" % d["def"][0] if d["def"] else ""
                w.writerow([fmt_id(i), "yes" if d["def"] else "no", definition,
                            ";".join(evidence_files(d, "impl")),
                            ";".join(evidence_files(d, "test")),
                            ";".join(evidence_files(d, "doc")),
                            ";".join(evidence_files(d, "proof")),
                            ";".join(evidence_files(d, "other")),
                            ";".join(sorted("%s:%s" % (k, t) for k in KINDS for t in d["link"][k]))])
        print("wrote %s" % args.csv)

    failed = bool(errors) or (args.strict and bool(undefined or orphan or notest))
    print("RESULT: %s" % ("FAIL" if failed else "OK (links resolve; this says nothing about test results)"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())