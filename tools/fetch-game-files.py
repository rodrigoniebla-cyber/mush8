#!/usr/bin/env python3
# Mush8 - fetch-game-files.py
# Gathers prod.keys, base.nsp, update.nsp (and optionally dlc.nsp / Firmware)
# from Google Drive links, direct URLs and already-downloaded files, unpacks
# .zip / .rar / .7z archives, and puts each file where make-ios.sh expects it.
#
#   python3 -I tools/fetch-game-files.py --dest . --work work/download \
#       [--local DIR] [--nxfs target/release/nxfs] LINK [LINK ...]
#
# LINK can be a Google Drive file or folder link (shared as "Anyone with the
# link"), or any direct http(s) download URL. Links may also be separated by
# commas or newlines inside one argument.
import argparse
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ARCHIVES = (".zip", ".rar", ".7z")
BASE_ID = 0x0100152000022000


def log(msg):
    print(f"[fetch] {msg}", flush=True)


def fail(msg):
    print(f"::error::{msg}", flush=True)
    sys.exit(1)


def split_links(values):
    out = []
    for v in values:
        out += [s for s in re.split(r"[\s,]+", v) if s]
    return out


def drive_target(url):
    """Returns ("folder"|"file", id) for a Google Drive link, else None."""
    p = urllib.parse.urlparse(url)
    if p.hostname not in ("drive.google.com", "docs.google.com", "drive.usercontent.google.com"):
        return None
    m = re.search(r"/folders/([A-Za-z0-9_-]+)", p.path)
    if m:
        return "folder", m.group(1)
    m = re.search(r"/d/([A-Za-z0-9_-]+)", p.path)
    if m:
        return "file", m.group(1)
    q = urllib.parse.parse_qs(p.query).get("id")
    if q:
        return "file", q[0]
    fail(f"can't find a file or folder id in this Google Drive link: {url}")


def download(url, into):
    into.mkdir(parents=True, exist_ok=True)
    target = drive_target(url)
    if target:
        kind, fid = target
        log(f"Google Drive {kind} {fid}")
        cmd = ["gdown", "--continue", "-O", f"{into}{os.sep}"]
        if kind == "folder":
            cmd += ["--folder", f"https://drive.google.com/drive/folders/{fid}"]
        else:
            cmd += [f"https://drive.google.com/uc?id={fid}"]
        r = subprocess.run(cmd)
        if r.returncode != 0:
            fail(
                f"Google Drive download failed for {url}. Check it's shared as 'Anyone with the link'. "
                "If Drive says too many people downloaded it, wait a day or make a copy of the file in your Drive and share that copy."
            )
        return
    if urllib.parse.urlparse(url).scheme not in ("http", "https"):
        fail(f"not a link: {url}")
    name = Path(urllib.parse.unquote(urllib.parse.urlparse(url).path)).name or "download"
    log(f"downloading {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "mush8-fetch"})
    with urllib.request.urlopen(req) as r:
        cd = r.headers.get("Content-Disposition", "")
        m = re.search(r"filename\*?=(?:UTF-8'')?\"?([^\";]+)", cd)
        if m:
            name = Path(urllib.parse.unquote(m.group(1))).name
        dest = into / name
        with open(dest, "wb") as f:
            shutil.copyfileobj(r, f, 8 << 20)
    log(f"  -> {dest.name} ({dest.stat().st_size / 1e9:.2f} GB)")


def is_first_volume(p):
    n = p.name.lower()
    m = re.search(r"\.part(\d+)\.rar$", n)
    if m:
        return int(m.group(1)) == 1
    if re.search(r"\.(r\d\d|z\d\d)$", n):
        return False
    m = re.search(r"\.(zip|7z)\.(\d{3})$", n)
    if m:
        return m.group(2) == "001"
    return n.endswith(ARCHIVES)


def volumes_of(p):
    n = p.name
    m = re.match(r"(.*)\.part\d+\.rar$", n, re.I)
    if m:
        return [q for q in p.parent.iterdir() if re.match(re.escape(m.group(1)) + r"\.part\d+\.rar$", q.name, re.I)]
    m = re.match(r"(.*)\.(zip|7z)\.\d{3}$", n, re.I)
    if m:
        return [q for q in p.parent.iterdir() if re.match(re.escape(m.group(1) + "." + m.group(2)) + r"\.\d{3}$", q.name, re.I)]
    stem = p.with_suffix("")
    extra = [q for q in p.parent.iterdir() if q.parent == p.parent and re.fullmatch(re.escape(stem.name) + r"\.(r|z)\d\d", q.name, re.I)]
    return [p] + extra


def sevenzip():
    for tool in ("7zz", "7z"):
        if shutil.which(tool):
            return tool
    fail("7-Zip is needed to unpack archives (brew install sevenzip / apt install 7zip)")


def extract_all(root):
    """Unpacks every archive under root (archives inside archives too)."""
    done = set()
    while True:
        todo = [p for p in sorted(root.rglob("*")) if p.is_file() and p not in done and is_first_volume(p)]
        if not todo:
            return
        for arc in todo:
            done.add(arc)
            out = arc.parent / (re.sub(r"(\.part\d+)?\.(zip|rar|7z)(\.\d{3})?$", "", arc.name, flags=re.I) + ".unpacked")
            log(f"unpacking {arc.relative_to(root)}")
            r = subprocess.run([sevenzip(), "x", "-y", "-bso0", "-bsp0", f"-o{out}", str(arc)])
            if r.returncode != 0:
                fail(f"couldn't unpack {arc.name} (wrong password, damaged, or a volume is missing)")
            for v in volumes_of(arc):
                v.unlink(missing_ok=True)


def nsp_info(nxfs, keys, nsp):
    if not nxfs or not keys:
        return None
    r = subprocess.run([nxfs, "--keys", str(keys), "info", str(nsp)], capture_output=True, text=True)
    if r.returncode != 0:
        log(f"  nxfs couldn't read {nsp.name}: {r.stderr.strip().splitlines()[-1:] or ''}")
        return None
    ncas = []
    for line in r.stdout.splitlines():
        m = re.match(r"\s+\S+ (\w+) program=([0-9a-f]{16})", line)
        if m:
            ncas.append((m.group(1), int(m.group(2), 16)))
    return ncas


def classify(nsps, nxfs, keys):
    found = {}
    unsure = []
    for p in nsps:
        info = nsp_info(nxfs, keys, p)
        kind = None
        if info:
            types = {t for t, _ in info}
            progs = [pid for t, pid in info if t == "Program"]
            if "PublicData" in types:
                kind = "dlc"
            elif progs and progs[0] & 0xFFF == 0x800:
                kind = "update"
            elif progs and progs[0] & 0xFFF == 0:
                kind = "base"
            if progs and progs[0] & ~0xFFF != BASE_ID:
                log(f"  warning: {p.name} is title {progs[0]:016x}, not Mario Kart 8 Deluxe")
        if not kind:
            n = p.name.lower()
            if re.search(r"dlc|booster|add.?on|0100152000023", n):
                kind = "dlc"
            elif re.search(r"upd|update|patch|0100152000022800|\[v[1-9]\d*\]|v4\.0\.1|v3\.0\.5", n):
                kind = "update"
        if kind:
            log(f"  {p.name}: {kind}")
            if kind in found:
                log(f"  warning: more than one {kind} .nsp, keeping {found[kind].name}")
                continue
            found[kind] = p
        else:
            unsure.append(p)
    for p in sorted(unsure, key=lambda q: q.stat().st_size, reverse=True):
        kind = "base" if "base" not in found else "update" if "update" not in found else None
        if kind:
            log(f"  {p.name}: {kind} (guessed from size)")
            found[kind] = p
    return found


def find_keys(root):
    cands = [p for p in root.rglob("*.keys") if p.is_file()]
    cands.sort(key=lambda p: (p.name.lower() != "prod.keys", len(p.parts)))
    for p in cands:
        try:
            if "header_key" in p.read_text(errors="replace"):
                return p
        except OSError:
            pass
    return cands[0] if cands else None


def find_firmware(root):
    best = None
    for d in [root] + [p for p in root.rglob("*") if p.is_dir()]:
        n = sum(1 for q in d.iterdir() if q.is_file() and q.name.lower().endswith(".nca"))
        if n >= 20 and (best is None or d.name.lower() == "firmware"):
            best = d
    return best


def place(src, dest):
    if dest.is_symlink() or dest.is_file():
        dest.unlink()
    elif dest.is_dir():
        shutil.rmtree(dest)
    shutil.move(str(src), str(dest))
    log(f"{dest.name} ready")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dest", default=".", type=Path)
    ap.add_argument("--work", default="work/download", type=Path)
    ap.add_argument("--local", action="append", default=[], type=Path, help="folder with already downloaded/uploaded files")
    ap.add_argument("--nxfs", default="target/release/nxfs")
    ap.add_argument("links", nargs="*")
    a = ap.parse_args()

    dest = a.dest.resolve()
    work = a.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    for i, link in enumerate(split_links(a.links)):
        download(link, work / f"link{i}")
    for d in a.local:
        if d.is_dir():
            for p in d.iterdir():
                shutil.move(str(p), str(work / p.name))
    extract_all(work)

    keys = find_keys(work)
    if keys:
        place(keys, dest / "prod.keys")
    elif not (dest / "prod.keys").exists():
        fail("no prod.keys found in the links / uploads")
    keys = dest / "prod.keys"

    nxfs = a.nxfs if Path(a.nxfs).is_file() else None
    nsps = [p for p in work.rglob("*") if p.is_file() and p.suffix.lower() == ".nsp"]
    for p in work.rglob("*"):
        if p.suffix.lower() in (".nsz", ".xci", ".xcz"):
            log(f"warning: {p.name} skipped, only .nsp is supported (convert it to .nsp first)")
    found = classify(nsps, nxfs, keys)
    for kind in ("base", "update", "dlc"):
        if kind in found:
            place(found[kind], dest / f"{kind}.nsp")
    fw = find_firmware(work)
    if fw:
        place(fw, dest / "Firmware")

    missing = [n for n in ("base.nsp", "update.nsp") if not (dest / n).exists()]
    if missing:
        fail(f"missing {', '.join(missing)}: none of the .nsp files looked like it")
    shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
