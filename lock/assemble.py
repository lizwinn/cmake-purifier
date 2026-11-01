# SPDX-License-Identifier: MIT
#
# Writes the lockfile from what the lock run recorded.
#
#   python3 -I assemble.py <observed.json> <http.jsonl> <git.jsonl> <flags.json>
#     <lock version> <lockfile> <git> <nix-prefetch-git> <build dir> <prefix>
#
# <observed.json> is the record of the lock run's dependency provider: the
# top-level project() and every FetchContent_MakeAvailable() dependency
# with its declared download and its source directory. <http.jsonl> is the
# record of the proxy (record.py), a line per response. <git.jsonl> is the
# record of the git wrapper, a line per git command with its working
# directory and arguments. <flags.json> is the configure arguments.
#
# Every successful GET the build made becomes a file artifact, under the
# URL the build asked for: a redirect counts as the file it leads to, and
# the URL it leads to is left out, since such targets are often signed
# URLs that expire. Every git clone becomes a checkout artifact at the
# commit the build checked out, hashed with nix-prefetch-git.
#
# The outputs come from the install into <prefix>: `files` is every file
# the install wrote (install_manifest.txt in <build dir>), relative to
# <prefix>. `targets` maps each installed target of the File API's code
# model in <build dir> to its type and the installed files of its
# artifacts. When the lock run did not build, there is no install and the
# lockfile records no outputs.
import json
import os
import subprocess
import sys
import urllib.parse

(
    observed_path,
    http_path,
    git_path,
    flags_path,
    lock_version,
    lockfile,
    git,
    prefetch,
    build_dir,
    prefix,
) = sys.argv[1:]


def fail(message):
    print(f"cmake-purifier: {message}", file=sys.stderr)
    sys.exit(1)


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path) as lines:
        return [json.loads(line) for line in lines if line.strip()]


def url_path(url):
    """The path mitm-cache replays a URL from: <scheme>/<host>/<path>."""
    parts = urllib.parse.urlsplit(url)
    host = parts.hostname or ""
    if parts.port and not (parts.scheme == "https" and parts.port == 443):
        host = f"{host}:{parts.port}"
    components = [c for c in parts.path.split("/") if c]
    return "/".join([parts.scheme, host, *components])


with open(observed_path) as f:
    observed = json.load(f)
with open(flags_path) as f:
    flags = json.load(f)

# File downloads.
responses = {}
targets = set()
for entry in read_lines(http_path):
    if entry["method"] != "GET":
        continue
    responses[entry["url"]] = entry
    if "location" in entry:
        targets.add(urllib.parse.urljoin(entry["url"], entry["location"]))


def final_hash(url):
    seen = set()
    while url in responses and url not in seen:
        seen.add(url)
        entry = responses[url]
        if "hash" in entry:
            return entry["hash"]
        if "location" not in entry:
            return None
        url = urllib.parse.urljoin(url, entry["location"])
    return None


files: dict[str, dict] = {}
paths: dict[str, str] = {}
for url in responses:
    if url in targets:
        continue
    file_hash = final_hash(url)
    if file_hash is None:
        continue
    path = url_path(url)
    if path in paths and paths[path] != url:
        fail(f"{paths[path]} and {url} differ only in their query, which the replay cannot tell apart")
    paths[path] = url
    files[url] = {"path": path, "url": url, "mirrors": [], "hash": file_hash}

# Git checkouts, from the git wrapper's record.
GLOBAL_WITH_VALUE = {"-C", "-c"}


def command(entry):
    """The working directory and the arguments after git's global options."""
    cwd = entry["cwd"]
    args = entry["args"]
    i = 0
    while i < len(args):
        if args[i] == "-C":
            cwd = os.path.join(cwd, args[i + 1])
            i += 2
        elif args[i] in GLOBAL_WITH_VALUE:
            i += 2
        elif args[i].startswith("--git-dir=") or args[i] in ("--no-pager",):
            i += 1
        else:
            break
    return os.path.normpath(cwd), args[i:]


clones: dict[str, dict] = {}
for entry in read_lines(git_path):
    cwd, args = command(entry)
    if not args:
        continue
    if args[0] == "clone" and len(args) >= 3:
        url, dest = args[-2], args[-1]
        directory = os.path.normpath(os.path.join(cwd, dest))
        clones[directory] = {"url": url, "dir": directory, "ref": None, "submodules": False}
    elif cwd in clones and args[0] == "checkout":
        refs = [a for a in args[1:] if not a.startswith("-")]
        if refs:
            clones[cwd]["ref"] = refs[0]
    elif cwd in clones and args[0] == "submodule" and "update" in args:
        clones[cwd]["submodules"] = True

checkouts: dict[tuple, dict] = {}
git_artifacts: dict[tuple, dict] = {}
by_dir: dict[str, dict] = {}
for clone in clones.values():
    if not os.path.isdir(clone["dir"]):
        fail(f"the lock run cloned {clone['url']} into {clone['dir']}, which no longer exists")
    rev = subprocess.run(
        [git, "-C", clone["dir"], "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    key = (clone["url"], rev, clone["submodules"])
    if key not in git_artifacts:
        print(f"cmake-purifier: hashing {clone['url']} at {rev}", file=sys.stderr)
        command_line = [prefetch, "--quiet", "--url", clone["url"], "--rev", rev]
        if clone["submodules"]:
            command_line.append("--fetch-submodules")
        result = subprocess.run(command_line, check=True, capture_output=True, text=True)
        git_artifacts[key] = {
            "path": "/".join(["git", url_path(clone["url"]), rev]),
            "git": {"url": clone["url"], "rev": rev, "submodules": clone["submodules"]},
            "hash": json.loads(result.stdout)["hash"],
        }
    artifact = git_artifacts[key]
    by_dir[clone["dir"]] = artifact
    ref = clone["ref"] or rev
    checkouts[(clone["url"], ref)] = {"url": clone["url"], "ref": ref, "artifact": artifact["path"]}

# FetchContent_MakeAvailable() dependencies, from the provider's record.
dependencies: list[dict] = []
for dep in observed["dependencies"]:
    if dep["type"] == "url":
        # CMake tries the declared URLs in order and stops at the first
        # that works, so the proxy saw that one; the others are mirrors.
        urls = dep["urls"]
        fetched = [u for u in urls if u in files]
        if not fetched:
            fail(f"the lock run saw no download of {urls[0]} for dependency {dep['name']}")
        artifact = files[fetched[0]]
        artifact["mirrors"] = [u for u in urls if u != fetched[0]]
        dependencies.append(
            {"name": dep["name"], "artifact": artifact["path"], "extract": dep["extract"]}
        )
    else:
        source_dir = os.path.normpath(dep["sourceDir"])
        if source_dir not in by_dir:
            fail(f"the lock run saw no git clone into {source_dir} for dependency {dep['name']}")
        dependencies.append({"name": dep["name"], "artifact": by_dir[source_dir]["path"]})

# Outputs, from the install and the File API.
outputs = None
manifest = os.path.join(build_dir, "install_manifest.txt")
if os.path.isdir(prefix) and os.path.exists(manifest):
    root = os.path.realpath(prefix)
    with open(manifest) as lines:
        installed = sorted(
            os.path.relpath(line.strip(), root) for line in lines if line.strip()
        )
    installed_set = set(installed)
    targets: dict[str, dict] = {}
    reply = os.path.join(build_dir, ".cmake", "api", "v1", "reply")
    indexes = sorted(f for f in os.listdir(reply) if f.startswith("index-"))
    if not indexes:
        fail(f"CMake wrote no File API reply in {reply}")
    with open(os.path.join(reply, indexes[-1])) as f:
        index = json.load(f)
    codemodel_file = next(
        o["jsonFile"] for o in index["objects"] if o["kind"] == "codemodel"
    )
    with open(os.path.join(reply, codemodel_file)) as f:
        codemodel = json.load(f)
    for target_ref in codemodel["configurations"][0]["targets"]:
        with open(os.path.join(reply, target_ref["jsonFile"])) as f:
            target = json.load(f)
        if "install" not in target:
            continue
        names = {os.path.basename(a["path"]) for a in target.get("artifacts", [])}
        target_files = sorted(
            os.path.join(d["path"], n)
            for d in target["install"]["destinations"]
            for n in names
            if os.path.join(d["path"], n) in installed_set
        )
        if target_files:
            targets[target["name"]] = {"type": target["type"], "files": target_files}
    outputs = {"files": installed, "targets": targets}

lock = {
    "version": int(lock_version),
    "project": observed["project"],
    "cmakeFlags": flags,
    "artifacts": sorted(
        [*files.values(), *git_artifacts.values()], key=lambda a: a["path"]
    ),
    "dependencies": sorted(dependencies, key=lambda d: d["name"]),
    "gitCheckouts": sorted(checkouts.values(), key=lambda c: (c["url"], c["ref"])),
    "outputs": outputs,
}
with open(lockfile + ".tmp", "w") as out:
    json.dump(lock, out, indent=2)
    out.write("\n")
os.replace(lockfile + ".tmp", lockfile)
print(
    f"cmake-purifier: wrote {lockfile} with {len(files)} files and {len(git_artifacts)} git checkouts",
    file=sys.stderr,
)
