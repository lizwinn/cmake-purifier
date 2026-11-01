# SPDX-License-Identifier: MIT
#
# Writes the lockfile from what the lock run recorded.
#
#   python3 -I assemble.py <work dir> <lock version> <lockfile> <nixpkgs>
#     <nix lib dir> <git> <hg> <svn> <nix-prefetch-git>
#
# <nix lib dir> is this project's nix/lib, which holds prefetch-vcs.nix.
#
# <work dir> is the lock run's scratch directory, which holds:
#
# - observed.json, the record of the dependency provider: the top-level
#   project() and every FetchContent_MakeAvailable() dependency with its
#   declared download and its source directory.
# - http.jsonl, the record of the proxy (record.py), a line per response.
# - git.jsonl, hg.jsonl, svn.jsonl and cvs.jsonl, the records of the tool
#   wrappers, a line per command with its working directory and arguments.
# - flags.json, the configure arguments.
# - build/ and prefix/, the build directory and the install.
#
# Every successful GET the build made becomes a file artifact, under the
# URL the build asked for: a redirect counts as the file it leads to, and
# the URL it leads to is left out, since such targets are often signed
# URLs that expire. Every git clone becomes a checkout artifact at the
# commit the build checked out, hashed with nix-prefetch-git. Every
# Mercurial, Subversion and CVS checkout becomes an artifact too, hashed by
# building the fetcher of the sandbox build (nix/lib/prefetch-vcs.nix).
#
# The outputs come from the install into prefix/: `files` is every file
# the install wrote (install_manifest.txt in build/), relative to prefix/.
# `targets` maps each installed target of the File API's code model in
# build/ to its type and the installed files of its artifacts. When the
# lock run did not build, there is no install and the lockfile records no
# outputs.
import datetime
import json
import os
import re
import subprocess
import sys
import urllib.parse
from typing import NoReturn

# python3 -I leaves the script's own directory out of the module path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from urls import https_of, url_path

(work, lock_version, lockfile, nixpkgs, nixlib, git, hg, svn, prefetch) = sys.argv[1:]
prefetch_vcs = os.path.join(nixlib, "prefetch-vcs.nix")
build_dir = os.path.join(work, "build")
prefix = os.path.join(work, "prefix")


def fail(message) -> NoReturn:
    print(f"cmake-purifier: {message}", file=sys.stderr)
    sys.exit(1)


def read_lines(name):
    path = os.path.join(work, name)
    if not os.path.exists(path):
        return []
    with open(path) as lines:
        return [json.loads(line) for line in lines if line.strip()]


def run(*command):
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout.strip()


def plain(text):
    """A path component of any text."""
    return re.sub(r"[^A-Za-z0-9+._=-]", "_", text).strip("_") or "_"


with open(os.path.join(work, "observed.json")) as f:
    observed = json.load(f)
with open(os.path.join(work, "flags.json")) as f:
    flags = json.load(f)

# File downloads.
responses = {}
targets = set()
for entry in read_lines("http.jsonl"):
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


def command(entry, with_value):
    """The working directory and the arguments after the global options,
    given the global options that take a value."""
    cwd = entry["cwd"]
    args = entry["args"]
    options = {}
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "-C" and "-C" in with_value:
            cwd = os.path.join(cwd, args[i + 1])
            i += 2
        elif arg in with_value:
            options[arg] = args[i + 1]
            i += 2
        elif arg.startswith("-"):
            i += 1
        else:
            break
    return os.path.normpath(cwd), args[i:], options


artifacts: dict[str, dict] = {}
by_dir: dict[str, dict] = {}


def vcs_artifact(artifact):
    """Adds the hash of a Mercurial, Subversion or CVS artifact, by
    building its fetcher with a wrong hash and reading the right one."""
    if artifact["path"] in artifacts:
        return artifacts[artifact["path"]]
    print(f"cmake-purifier: hashing {artifact['path']}", file=sys.stderr)
    result = subprocess.run(
        [
            "nix-build", "--no-out-link", prefetch_vcs,
            "--arg", "nixpkgs", nixpkgs,
            "--argstr", "artifact", json.dumps(artifact),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    found = re.search(r"got:\s+(sha256-[A-Za-z0-9+/=]+)", result.stderr)
    if found is None:
        fail(f"could not hash {artifact['path']}:\n{result.stderr}")
    artifact = {**artifact, "hash": found.group(1)}
    artifacts[artifact["path"]] = artifact
    return artifact


# Git checkouts.
git_clones: dict[str, dict] = {}
for entry in read_lines("git.jsonl"):
    cwd, args, _ = command(entry, {"-C", "-c"})
    if not args:
        continue
    if args[0] == "clone" and len(args) >= 3:
        url, dest = args[-2], args[-1]
        directory = os.path.normpath(os.path.join(cwd, dest))
        git_clones[directory] = {"url": url, "ref": None, "submodules": False}
    elif cwd in git_clones and args[0] == "checkout":
        refs = [a for a in args[1:] if not a.startswith("-")]
        if refs:
            git_clones[cwd]["ref"] = refs[0]
    elif cwd in git_clones and args[0] == "submodule" and "update" in args:
        git_clones[cwd]["submodules"] = True

git_checkouts: dict[tuple, dict] = {}
for directory, clone in git_clones.items():
    if not os.path.isdir(directory):
        fail(f"the lock run cloned {clone['url']} into {directory}, which no longer exists")
    rev = run(git, "-C", directory, "rev-parse", "HEAD")
    # The sandbox has no SSH credentials, so a repository cloned over SSH
    # is fetched from the HTTPS URL of the same host when that host serves
    # it there. The checkout keeps the SSH URL, which the shim matches.
    fetch_urls = [u for u in [https_of(clone["url"]), clone["url"]] if u]
    path = "/".join(["git", url_path(fetch_urls[0]), rev])
    if path not in artifacts:
        for fetch_url in fetch_urls:
            print(f"cmake-purifier: hashing {fetch_url} at {rev}", file=sys.stderr)
            command_line = [prefetch, "--quiet", "--url", fetch_url, "--rev", rev]
            if clone["submodules"]:
                command_line.append("--fetch-submodules")
            result = subprocess.run(command_line, capture_output=True, text=True, check=False)
            if result.returncode == 0:
                break
        else:
            fail(f"could not fetch {clone['url']} at {rev}:\n{result.stderr}")
        artifacts[path] = {
            "path": path,
            # The shim answers every command a build makes on a checkout,
            # so no checkout needs a real .git.
            "git": {
                "url": fetch_url,
                "rev": rev,
                "submodules": clone["submodules"],
                "leaveDotGit": False,
                "commitObject": None,
            },
            "hash": json.loads(result.stdout)["hash"],
        }
    by_dir[directory] = artifacts[path]
    ref = clone["ref"] or rev
    git_checkouts[(clone["url"], ref)] = {"url": clone["url"], "ref": ref, "artifact": path}

# Mercurial checkouts: `hg clone -U <url> <dir>`, then `hg update <tag>`.
hg_clones: dict[str, dict] = {}
for entry in read_lines("hg.jsonl"):
    cwd, args, _ = command(entry, {"--cwd", "-R", "--repository", "--config"})
    if not args:
        continue
    if args[0] == "clone":
        positional = [a for a in args[1:] if not a.startswith("-")]
        if len(positional) >= 2:
            directory = os.path.normpath(os.path.join(cwd, positional[1]))
            hg_clones[directory] = {"url": positional[0], "ref": ""}
    elif cwd in hg_clones and args[0] in ("update", "up"):
        refs = [a for a in args[1:] if not a.startswith("-")]
        hg_clones[cwd]["ref"] = refs[0] if refs else ""

hg_checkouts: dict[tuple, dict] = {}
for directory, clone in hg_clones.items():
    node = run(hg, "--cwd", directory, "log", "-r", ".", "-T", "{node}")
    subrepos = os.path.exists(os.path.join(directory, ".hgsub"))
    artifact = vcs_artifact({
        "path": "/".join(["hg", url_path(clone["url"]), node]),
        "hg": {"url": clone["url"], "rev": node, "subrepos": subrepos},
    })
    by_dir[directory] = artifact
    hg_checkouts[(clone["url"], clone["ref"])] = {
        "repo": clone["url"], "ref": clone["ref"], "artifact": artifact["path"],
    }

# Subversion checkouts: `svn co <url> [-r<rev>] ... <dir>`.
svn_checkouts: dict[tuple, dict] = {}
for entry in read_lines("svn.jsonl"):
    cwd = os.path.normpath(entry["cwd"])
    args = entry["args"]
    if not args or args[0] not in ("co", "checkout"):
        continue
    positional = []
    ref = ""
    i = 1
    while i < len(args):
        if args[i] == "-r":
            ref = args[i + 1]
            i += 2
        elif args[i].startswith("-r"):
            ref = args[i][2:]
            i += 1
        elif args[i].startswith("-"):
            i += 1
        else:
            positional.append(args[i])
            i += 1
    url = positional[0]
    directory = os.path.normpath(os.path.join(cwd, positional[-1]))
    rev = int(run(svn, "info", "--show-item", "revision", directory))
    artifact = vcs_artifact({
        "path": "/".join(["svn", url_path(url), str(rev)]),
        # ExternalProject's `svn co` fetches externals and expands keywords.
        "svn": {"url": url, "rev": rev, "ignoreExternals": False, "ignoreKeywords": False},
    })
    by_dir[directory] = artifact
    svn_checkouts[(url, ref)] = {"repo": url, "ref": ref, "artifact": artifact["path"]}

# CVS checkouts: `cvs -d <root> co [-r<tag> | -D<date>] -d <dir> <module>`.
# A checkout without a tag or a date locks the time of the lock run.
lock_time = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d %H:%M:%S UTC")
cvs_checkouts: dict[tuple, dict] = {}
for entry in read_lines("cvs.jsonl"):
    cwd, args, options = command(entry, {"-d", "-z", "-s", "-T", "-e"})
    if not args or args[0] not in ("co", "checkout"):
        continue
    root = options.get("-d", os.environ.get("CVSROOT", ""))
    ref = ""
    tag = None
    date = None
    directory = ""
    module = None
    i = 1
    while i < len(args):
        arg = args[i]
        if arg in ("-r", "-D", "-d"):
            value = args[i + 1]
            i += 2
        elif arg[:2] in ("-r", "-D", "-d") and len(arg) > 2:
            arg, value = arg[:2], arg[2:]
            i += 1
        elif arg.startswith("-"):
            i += 1
            continue
        else:
            module = arg
            i += 1
            continue
        if arg == "-r":
            tag, ref = value, f"r:{value}"
        elif arg == "-D":
            date, ref = value, f"D:{value}"
        else:
            directory = value
    if module is None:
        fail(f"the lock run made a cvs checkout without a module: {args}")
    directory = os.path.normpath(os.path.join(cwd, directory or module))
    if tag is None and date is None:
        date = lock_time
    artifact = vcs_artifact({
        "path": "/".join(["cvs", plain(root), plain(module), plain(tag or date)]),
        "cvs": {"cvsRoot": root, "module": module, "tag": tag, "date": date},
    })
    by_dir[directory] = artifact
    repo = f"{root} {module}"
    cvs_checkouts[(repo, ref)] = {"repo": repo, "ref": ref, "artifact": artifact["path"]}

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
            fail(f"the lock run saw no {dep['type']} checkout into {source_dir} for dependency {dep['name']}")
        dependency = {"name": dep["name"], "artifact": by_dir[source_dir]["path"]}
        # A GIT_SUBMODULES list: the checkout holds every submodule, and
        # the source of the dependency only the listed ones.
        if dep["type"] == "git" and dep.get("submodulePaths"):
            dependency["submodules"] = dep["submodulePaths"]
        dependencies.append(dependency)

# Outputs, from the install and the File API.
outputs = None
manifest = os.path.join(build_dir, "install_manifest.txt")
if os.path.isdir(prefix) and os.path.exists(manifest):
    root_dir = os.path.realpath(prefix)
    with open(manifest) as lines:
        installed = sorted(
            os.path.relpath(line.strip(), root_dir) for line in lines if line.strip()
        )
    installed_set = set(installed)
    installed_targets: dict[str, dict] = {}
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
            installed_targets[target["name"]] = {"type": target["type"], "files": target_files}
    outputs = {"files": installed, "targets": installed_targets}


def by_repo_ref(table):
    return sorted(table.values(), key=lambda c: (c.get("url", c.get("repo")), c["ref"]))


lock = {
    "version": int(lock_version),
    "project": observed["project"],
    "cmakeFlags": flags,
    "artifacts": sorted([*files.values(), *artifacts.values()], key=lambda a: a["path"]),
    "dependencies": sorted(dependencies, key=lambda d: d["name"]),
    "gitCheckouts": by_repo_ref(git_checkouts),
    "hgCheckouts": by_repo_ref(hg_checkouts),
    "svnCheckouts": by_repo_ref(svn_checkouts),
    "cvsCheckouts": by_repo_ref(cvs_checkouts),
    "outputs": outputs,
}
with open(lockfile + ".tmp", "w") as out:
    json.dump(lock, out, indent=2)
    out.write("\n")
os.replace(lockfile + ".tmp", lockfile)
print(
    f"cmake-purifier: wrote {lockfile} with {len(files)} files and "
    f"{len(artifacts)} checkouts",
    file=sys.stderr,
)
