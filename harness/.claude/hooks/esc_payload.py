#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Derive the RESULTING FILE BYTES of a proposed Edit/Write, for byte-exact approval.

ratchet - .claude/hooks/esc_payload.py

HUMANS: you should not need to edit this file. It is part of the control layer
(CONTRACT §5.6 control set adjacency) and it decides what an approval is bound
to. Changing it changes what "byte-exact" means.

Contract ....... CONTRACT.md §5.5 (approvals are byte-bound), §0.2 (py3.8+,
                 stdlib only, utf-8 everywhere), §4.2 (stdout shim)
Invoked by ..... escalation-lib.sh esc_target_sha / esc_target_path, which is
                 in turn called by scope-guard.sh on Edit|Write|NotebookEdit.
Input .......... the hook payload JSON on stdin (or --payload-file). Both the
                 full hook envelope {"tool_name":...,"tool_input":{...}} and a
                 bare tool_input object are accepted.
Output ......... one line: "<KIND> <sha256|->" on stdout.

WHY THIS EXISTS
    An approval signs a sha. For a Bash command the bytes are the command. For
    a write, signing the *diff* would let the same diff land on a different file
    state and produce a different file -- so we sign the RESULT, not the patch.
    That is only well-defined when the result is derivable. When it is not
    (an Edit whose old_string occurs more than once with replace_all unset) we
    say AMBIGUOUS rather than guessing, and the caller tells the agent to
    re-issue as Write with the complete content. Guessing here would be a
    silent downgrade of byte-exactness to patch-exactness.

EXIT CODES (frozen; escalation-lib.sh maps these)
    0  EXACT        resulting bytes derived; sha printed
    1  ERROR        malformed payload / unreadable file / bad arguments
    3  AMBIGUOUS    old_string occurs N>1 times and replace_all is not set
    4  NOTAWRITE    tool is not a write tool
    5  NOMATCH      old_string does not occur in the file
    6  NOFILE       Edit against a path that does not exist
    7  UNSUPPORTED  write shape whose result cannot be derived (NotebookEdit)
"""

import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

import argparse
import hashlib
import json
import os

EXACT, ERROR, AMBIGUOUS = 0, 1, 3
NOTAWRITE, NOMATCH, NOFILE, UNSUPPORTED = 4, 5, 6, 7

WRITE_TOOLS = ("Edit", "Write", "MultiEdit")
UNSUPPORTED_TOOLS = ("NotebookEdit",)


def sha256_bytes(data):
    """sha256 of exact bytes."""
    return hashlib.sha256(data).hexdigest()


def load_payload(text):
    """Accept the hook envelope or a bare tool_input object.

    Returns (tool_name_or_None, tool_input_dict). Raises ValueError on junk.
    """
    text = text.lstrip("\ufeff")  # strip a BOM a Windows editor may have added
    obj = json.loads(text)
    if not isinstance(obj, dict):
        raise ValueError("payload is not a JSON object")
    if "tool_input" in obj and isinstance(obj["tool_input"], dict):
        return obj.get("tool_name"), obj["tool_input"]
    return obj.get("tool_name"), obj


def resolve_path(repo_root, file_path):
    """Absolute path for a payload file_path; repo-relative paths resolve
    against repo_root. Windows separators are normalized."""
    if not file_path:
        return None
    p = str(file_path).replace("\\", "/").replace("\r", "")
    if os.path.isabs(p) or (len(p) > 2 and p[1] == ":"):
        return os.path.normpath(p)
    return os.path.normpath(os.path.join(repo_root, p))


def repo_rel(repo_root, abs_path):
    """Repo-relative POSIX path, or the absolute path if outside the repo."""
    if not abs_path:
        return "-"
    try:
        rel = os.path.relpath(abs_path, repo_root)
    except ValueError:
        return abs_path.replace("\\", "/")
    rel = rel.replace("\\", "/")
    if rel.startswith(".."):
        return abs_path.replace("\\", "/")
    return rel


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def derive(tool, tool_input, repo_root):
    """Return (exit_code, resulting_bytes_or_None, abs_path_or_None, note)."""
    if tool in UNSUPPORTED_TOOLS:
        return (UNSUPPORTED, None, resolve_path(repo_root, tool_input.get("notebook_path")),
                "NotebookEdit results are not derivable from the payload")
    if tool not in WRITE_TOOLS:
        return (NOTAWRITE, None, None, "not a write tool")

    path = resolve_path(repo_root, tool_input.get("file_path"))
    if path is None:
        return (ERROR, None, None, "payload has no file_path")

    # ---- Write: the payload IS the result. ---------------------------------
    if tool == "Write":
        content = tool_input.get("content")
        if content is None:
            return (ERROR, None, path, "Write payload has no content")
        if not isinstance(content, str):
            return (ERROR, None, path, "Write content is not a string")
        return (EXACT, content.encode("utf-8"), path, "write")

    # ---- MultiEdit: sequential edits, each must be unambiguous. ------------
    if tool == "MultiEdit":
        edits = tool_input.get("edits")
        if not isinstance(edits, list) or not edits:
            return (ERROR, None, path, "MultiEdit payload has no edits list")
        if not os.path.exists(path):
            return (NOFILE, None, path, "file does not exist")
        try:
            cur = read_bytes(path).decode("utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            return (ERROR, None, path, "cannot read file as utf-8: %s" % exc)
        for i, ed in enumerate(edits):
            if not isinstance(ed, dict):
                return (ERROR, None, path, "edit %d is not an object" % i)
            code, cur, note = apply_edit(cur, ed)
            if code != EXACT:
                return (code, None, path, "edit %d: %s" % (i, note))
        return (EXACT, cur.encode("utf-8"), path, "multiedit")

    # ---- Edit --------------------------------------------------------------
    if not os.path.exists(path):
        # An Edit against a missing file cannot succeed; there is no result to
        # sign. Distinguishable so the caller can say why.
        return (NOFILE, None, path, "file does not exist")
    try:
        cur = read_bytes(path).decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        return (ERROR, None, path, "cannot read file as utf-8: %s" % exc)
    code, out, note = apply_edit(cur, tool_input)
    if code != EXACT:
        return (code, None, path, note)
    return (EXACT, out.encode("utf-8"), path, "edit")


def apply_edit(text, ed):
    """Apply one Edit spec to text. Returns (code, text_or_None, note).

    The ambiguity rule, stated plainly: with replace_all unset and more than one
    occurrence, the tool itself would refuse -- and even if it did not, there is
    no single resulting file to sign. We report AMBIGUOUS instead of picking the
    first occurrence, because picking would produce a sha for a file the human
    never agreed to.
    """
    old = ed.get("old_string")
    new = ed.get("new_string")
    if old is None or new is None:
        return (ERROR, None, "edit payload lacks old_string/new_string")
    if not isinstance(old, str) or not isinstance(new, str):
        return (ERROR, None, "old_string/new_string are not strings")

    replace_all = ed.get("replace_all")
    if isinstance(replace_all, str):
        replace_all = replace_all.strip().lower() in ("1", "true", "yes")
    replace_all = bool(replace_all)

    if old == "":
        # Insert-at-start semantics are not defined for approval purposes.
        return (ERROR, None, "empty old_string has no derivable result")

    n = text.count(old)
    if n == 0:
        return (NOMATCH, None, "old_string does not occur in the file")
    if n > 1 and not replace_all:
        return (AMBIGUOUS, None,
                "old_string occurs %d times and replace_all is not set" % n)
    if replace_all:
        return (EXACT, text.replace(old, new), "replaced %d occurrence(s)" % n)
    return (EXACT, text.replace(old, new, 1), "replaced 1 occurrence")


KIND = {
    EXACT: "EXACT",
    ERROR: "ERROR",
    AMBIGUOUS: "AMBIGUOUS",
    NOTAWRITE: "NOTAWRITE",
    NOMATCH: "NOMATCH",
    NOFILE: "NOFILE",
    UNSUPPORTED: "UNSUPPORTED",
}


def selftest():
    """Every case below includes the input that makes it fail (§0.6)."""
    import tempfile
    import shutil

    fails = []

    def check(name, cond, detail=""):
        if not cond:
            fails.append("FAIL %s %s" % (name, detail))

    root = tempfile.mkdtemp()
    try:
        target = os.path.join(root, "a.txt")
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("alpha\nbeta\nalpha\n")

        # Write -> EXACT, and the sha is the sha of the content, nothing else.
        code, out, path, _ = derive("Write", {"file_path": "a.txt", "content": "hello\n"}, root)
        check("write-exact", code == EXACT and out == b"hello\n", "code=%s" % code)
        check("write-sha", sha256_bytes(out) == sha256_bytes(b"hello\n"))

        # Edit with a unique old_string -> EXACT resulting file.
        code, out, path, _ = derive(
            "Edit", {"file_path": "a.txt", "old_string": "beta", "new_string": "BETA"}, root)
        check("edit-exact", code == EXACT and out == b"alpha\nBETA\nalpha\n", "code=%s" % code)

        # Edit with a duplicated old_string and no replace_all -> AMBIGUOUS.
        code, out, path, note = derive(
            "Edit", {"file_path": "a.txt", "old_string": "alpha", "new_string": "A"}, root)
        check("edit-ambiguous", code == AMBIGUOUS and out is None, "code=%s note=%s" % (code, note))

        # Same edit WITH replace_all -> deterministic, therefore EXACT.
        code, out, path, _ = derive(
            "Edit", {"file_path": "a.txt", "old_string": "alpha",
                     "new_string": "A", "replace_all": True}, root)
        check("edit-replace-all", code == EXACT and out == b"A\nbeta\nA\n", "code=%s" % code)

        # old_string absent -> NOMATCH (distinct from AMBIGUOUS).
        code, out, path, _ = derive(
            "Edit", {"file_path": "a.txt", "old_string": "zzz", "new_string": "x"}, root)
        check("edit-nomatch", code == NOMATCH, "code=%s" % code)

        # missing file -> NOFILE.
        code, out, path, _ = derive(
            "Edit", {"file_path": "nope.txt", "old_string": "a", "new_string": "b"}, root)
        check("edit-nofile", code == NOFILE, "code=%s" % code)

        # NotebookEdit -> UNSUPPORTED, never silently EXACT.
        code, out, path, _ = derive("NotebookEdit", {"notebook_path": "n.ipynb"}, root)
        check("notebook-unsupported", code == UNSUPPORTED, "code=%s" % code)

        # Bash -> NOTAWRITE.
        code, out, path, _ = derive("Bash", {"command": "ls"}, root)
        check("bash-notawrite", code == NOTAWRITE, "code=%s" % code)

        # MultiEdit chains, and an ambiguous member poisons the whole thing.
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("one\ntwo\n")
        code, out, path, _ = derive(
            "MultiEdit",
            {"file_path": "a.txt",
             "edits": [{"old_string": "one", "new_string": "1"},
                       {"old_string": "two", "new_string": "2"}]}, root)
        check("multiedit-exact", code == EXACT and out == b"1\n2\n", "code=%s" % code)
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("dup\ndup\n")
        code, out, path, _ = derive(
            "MultiEdit",
            {"file_path": "a.txt", "edits": [{"old_string": "dup", "new_string": "x"}]}, root)
        check("multiedit-ambiguous", code == AMBIGUOUS, "code=%s" % code)

        # Envelope parsing: full hook payload and bare tool_input both work.
        name, ti = load_payload('{"tool_name":"Write","tool_input":{"file_path":"a","content":"c"}}')
        check("envelope-full", name == "Write" and ti.get("content") == "c")
        name, ti = load_payload('{"file_path":"a","content":"c"}')
        check("envelope-bare", ti.get("content") == "c")

        # utf-8 round trip: non-ASCII content hashes as utf-8 bytes.
        code, out, path, _ = derive(
            "Write", {"file_path": "u.txt", "content": u"café\n"}, root)
        check("utf8", code == EXACT and out == u"café\n".encode("utf-8"), "code=%s" % code)

        # repo_rel normalization
        check("repo-rel", repo_rel(root, os.path.join(root, "x", "y.txt")) == "x/y.txt")
    finally:
        shutil.rmtree(root, ignore_errors=True)

    for line in fails:
        print(line)
    if fails:
        print("esc_payload.py selftest FAIL")
        return 1
    print("esc_payload.py selftest PASS")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Derive the resulting bytes of a proposed Edit/Write.")
    ap.add_argument("--tool", default=None,
                    help="tool name; overrides tool_name in the payload")
    ap.add_argument("--repo-root", default=os.environ.get("REPO_ROOT") or os.getcwd())
    ap.add_argument("--payload-file", default=None,
                    help="read the payload JSON from this file instead of stdin")
    ap.add_argument("--out", default=None,
                    help="write the derived resulting bytes to this path")
    ap.add_argument("--print-path", action="store_true",
                    help="print the repo-relative target path instead of the sha")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    try:
        if args.payload_file:
            with open(args.payload_file, "r", encoding="utf-8", errors="replace") as fh:
                raw = fh.read()
        else:
            raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    except OSError as exc:
        print("ERROR -")
        sys.stderr.write("esc_payload: cannot read payload: %s\n" % exc)
        return ERROR

    try:
        payload_tool, tool_input = load_payload(raw)
    except (ValueError, TypeError) as exc:
        print("ERROR -")
        sys.stderr.write("esc_payload: malformed payload JSON: %s\n" % exc)
        return ERROR

    tool = args.tool or payload_tool or ""
    repo_root = os.path.abspath(args.repo_root)

    code, out, path, note = derive(tool, tool_input, repo_root)

    if args.print_path:
        print(repo_rel(repo_root, path) if path else "-")
        return code

    if code == EXACT and out is not None:
        digest = sha256_bytes(out)
        if args.out:
            try:
                with open(args.out, "wb") as fh:
                    fh.write(out)
            except OSError as exc:
                sys.stderr.write("esc_payload: cannot write --out: %s\n" % exc)
        print("%s %s" % (KIND[code], digest))
        return EXACT

    print("%s -" % KIND.get(code, "ERROR"))
    sys.stderr.write("esc_payload: %s (%s)\n" % (KIND.get(code, "ERROR"), note))
    return code


if __name__ == "__main__":
    sys.exit(main())
