#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
from pathlib import Path
from typing import Any


SESSION_ID_RE = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)


WARN_ONLY_CHANGE_PATHS = {
    ".agents",
    ".codex",
}

RED = "\033[31m"
YELLOW = "\033[33m"
RESET = "\033[0m"


def colorize_status(message: str) -> str:
    if message.startswith("[ERROR]"):
        return f"{RED}[ERROR]{RESET}" + message[len("[ERROR]"):]
    if message.startswith("[WARN]"):
        return f"{YELLOW}[WARN]{RESET}" + message[len("[WARN]"):]
    return message


def eprint(message: str) -> None:
    print(colorize_status(message), file=sys.stderr)


def is_warn_only_change_path(path: str) -> bool:
    return any(path == base or path.startswith(base + os.sep) for base in WARN_ONLY_CHANGE_PATHS)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_state_dir(args: argparse.Namespace) -> int:
    repo = str(Path(args.repo_root).resolve())
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.environ.get("HOME", ""), ".local", "state")
    key = hashlib.sha256(repo.encode("utf-8")).hexdigest()[:16]
    print(os.path.join(base, "ai-codex-orchestrator", key))
    return 0


def build_manifest(root: Path) -> dict[str, dict[str, Any]]:
    root = root.resolve()
    manifest: dict[str, dict[str, Any]] = {}

    for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        paths = [Path(dirpath)]
        paths += [Path(dirpath) / d for d in dirnames]
        paths += [Path(dirpath) / f for f in filenames]

        for path in paths:
            try:
                st = os.lstat(path)
            except FileNotFoundError:
                continue

            rel = os.path.relpath(path, root)
            rel = "." if rel == "." else rel
            mode = format(stat.S_IMODE(st.st_mode), "04o")

            if stat.S_ISLNK(st.st_mode):
                manifest[rel] = {
                    "type": "symlink",
                    "target": os.readlink(path),
                    "mode": mode,
                }
            elif stat.S_ISDIR(st.st_mode):
                manifest[rel] = {
                    "type": "dir",
                    "mode": mode,
                }
            elif stat.S_ISREG(st.st_mode):
                manifest[rel] = {
                    "type": "file",
                    "mode": mode,
                    "size": st.st_size,
                    "sha256": sha256_file(path),
                }
            else:
                manifest[rel] = {
                    "type": "other",
                    "mode": mode,
                }

    return manifest


def cmd_manifest(args: argparse.Namespace) -> int:
    root = Path(args.root)
    out = Path(args.out)
    manifest = build_manifest(root)
    out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    return 0


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def cmd_verify(args: argparse.Namespace) -> int:
    before = load_json(Path(args.before))
    after = load_json(Path(args.after))
    allowed = set(args.allowed)
    violations: list[tuple[str, str]] = []
    warn_only_changes: list[tuple[str, str]] = []

    for path in sorted(set(before) | set(after)):
        if path in allowed:
            continue

        if before.get(path) != after.get(path):
            if path not in before:
                kind = "created"
            elif path not in after:
                kind = "deleted"
            else:
                old = before[path].get("type") if path in before else None
                new = after[path].get("type") if path in after else None
                kind = "renamed/replaced" if old != new else "modified"

            if is_warn_only_change_path(path):
                warn_only_changes.append((kind, path))
            else:
                violations.append((kind, path))

    if warn_only_changes:
        eprint(f"[WARN] Changes detected in warn-only paths in {args.label}.")
        eprint("[WARN] These changes are displayed but are not treated as errors:")

        for kind, path in warn_only_changes[:300]:
            print(f"  - {kind}: {path}", file=sys.stderr)

        if len(warn_only_changes) > 300:
            print(f"  ... and {len(warn_only_changes) - 300} more", file=sys.stderr)

    if violations:
        eprint(f"[ERROR] Unauthorized changes detected in {args.label}.")
        print("Only these paths may differ:", file=sys.stderr)
        for p in sorted(allowed):
            print(f"  - {p}", file=sys.stderr)

        for kind, path in violations[:300]:
            print(f"  - {kind}: {path}", file=sys.stderr)

        if len(violations) > 300:
            print(f"  ... and {len(violations) - 300} more", file=sys.stderr)

        return 1

    return 0


def cmd_copytree(args: argparse.Namespace) -> int:
    src = Path(args.src).resolve()
    dst = Path(args.dst)

    if dst.exists():
        eprint(f"[ERROR] destination already exists: {dst}")
        return 1

    shutil.copytree(src, dst, symlinks=True)
    return 0


def cmd_validate_symlinks(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    violations: list[tuple[str, str]] = []

    for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        for name in dirnames + filenames:
            path = Path(dirpath) / name
            if not path.is_symlink():
                continue

            target = os.readlink(path)
            if os.path.isabs(target):
                resolved = Path(target)
            else:
                resolved = path.parent / target

            resolved_norm = Path(os.path.normpath(str(resolved)))
            candidates = [resolved_norm]

            if resolved_norm.exists():
                candidates.append(resolved_norm.resolve())

            for candidate in candidates:
                candidate_str = str(candidate)
                root_str = str(root)
                if candidate_str != root_str and not candidate_str.startswith(root_str + os.sep):
                    violations.append((os.path.relpath(path, root), target))
                    break

    if violations:
        eprint("[ERROR] Symlinks escaping the repository were found.")
        for rel, target in violations[:100]:
            print(f"  - {rel} -> {target}", file=sys.stderr)
        if len(violations) > 100:
            print(f"  ... and {len(violations) - 100} more", file=sys.stderr)
        return 1

    return 0


def assert_regular_file_for_copyback(src: Path, dst: Path) -> None:
    if not src.exists():
        raise RuntimeError(f"allowed file was not produced in the temporary repository: {src}")

    if src.is_symlink():
        raise RuntimeError(f"allowed file in temporary repository must not be a symlink: {src}")

    if not stat.S_ISREG(src.stat().st_mode):
        raise RuntimeError(f"allowed path in temporary repository is not a regular file: {src}")

    if os.path.lexists(dst):
        if dst.is_symlink():
            raise RuntimeError(f"allowed file in original repository must not be a symlink: {dst}")

        if not stat.S_ISREG(dst.stat().st_mode):
            raise RuntimeError(f"allowed path in original repository is not a regular file: {dst}")


def copy_one_file_back(work_repo: Path, repo_root: Path, rel: str) -> None:
    src = work_repo / rel
    dst = repo_root / rel

    assert_regular_file_for_copyback(src, dst)

    dst.parent.mkdir(parents=True, exist_ok=True)
    with src.open("rb") as s, dst.open("wb") as d:
        shutil.copyfileobj(s, d)

    os.chmod(dst, stat.S_IMODE(src.stat().st_mode))


def cmd_copyback(args: argparse.Namespace) -> int:
    work_repo = Path(args.work_repo)
    repo_root = Path(args.repo_root)

    try:
        for rel in args.paths:
            copy_one_file_back(work_repo, repo_root, rel)
    except RuntimeError as exc:
        eprint(f"[ERROR] {exc}")
        return 1

    return 0


def find_session_uuid(obj: Any) -> str | None:
    if isinstance(obj, dict):
        for key, value in obj.items():
            if "session" in str(key).lower() and isinstance(value, str):
                m = SESSION_ID_RE.search(value)
                if m:
                    return m.group(0)

            found = find_session_uuid(value)
            if found:
                return found

    elif isinstance(obj, list):
        for item in obj:
            found = find_session_uuid(item)
            if found:
                return found

    elif isinstance(obj, str):
        m = SESSION_ID_RE.search(obj)
        if m:
            return m.group(0)

    return None


def cmd_extract_session(args: argparse.Namespace) -> int:
    log_file = Path(args.log_file)
    out_file = Path(args.out_file)
    candidates: list[str] = []

    with log_file.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            try:
                obj = json.loads(line)
            except Exception:
                continue

            sid = find_session_uuid(obj)
            if sid:
                candidates.append(sid)

    if not candidates:
        eprint("[WARN] Could not extract Codex session id from JSON output.")
        eprint(f"[WARN] Set CODEX_SESSION_ID manually, or write it to: {out_file}")
        return 0

    sid = candidates[0]
    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text(sid + "\n", encoding="utf-8")

    print(f"[INFO] saved Codex session id: {sid}", file=sys.stderr)
    print(f"[INFO] session id file: {out_file}", file=sys.stderr)
    return 0


def cmd_validate_session_id(args: argparse.Namespace) -> int:
    sid = args.session_id

    if not sid:
        return 2

    if not SESSION_ID_RE.fullmatch(sid):
        eprint(f"[ERROR] invalid Codex session id: {sid!r}")
        return 1

    print(sid)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("state-dir")
    p.add_argument("repo_root")
    p.set_defaults(func=cmd_state_dir)

    p = sub.add_parser("manifest")
    p.add_argument("root")
    p.add_argument("out")
    p.set_defaults(func=cmd_manifest)

    p = sub.add_parser("verify")
    p.add_argument("before")
    p.add_argument("after")
    p.add_argument("label")
    p.add_argument("--allowed", nargs="+", required=True)
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("copytree")
    p.add_argument("src")
    p.add_argument("dst")
    p.set_defaults(func=cmd_copytree)

    p = sub.add_parser("validate-symlinks")
    p.add_argument("root")
    p.set_defaults(func=cmd_validate_symlinks)

    p = sub.add_parser("copyback")
    p.add_argument("work_repo")
    p.add_argument("repo_root")
    p.add_argument("paths", nargs="+")
    p.set_defaults(func=cmd_copyback)

    p = sub.add_parser("extract-session")
    p.add_argument("log_file")
    p.add_argument("out_file")
    p.set_defaults(func=cmd_extract_session)

    p = sub.add_parser("validate-session-id")
    p.add_argument("session_id")
    p.set_defaults(func=cmd_validate_session_id)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
