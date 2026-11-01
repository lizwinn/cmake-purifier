# SPDX-License-Identifier: MIT
#
# Reads the records of the lock run, with no access to anything else:
# assemble.py adds what needs the checkouts or the network, and
# test_records.py checks these functions on sample records.
#
# A tool record is a list of {cwd, args}, a command per entry, as the tool
# wrappers of `cmake-purifier lock` log them. An HTTP record is a list of
# {method, url, status, location?, hash?}, as lock/record.py logs them.
import os
import urllib.parse

from urls import url_path


class RecordError(Exception):
    pass


def file_artifacts(responses):
    """The file artifacts of an HTTP record, by URL.

    Every successful GET becomes an artifact under the URL the build asked
    for, with the hash of the file a redirect leads to. A URL that is only
    the target of a redirect is left out, since such targets are often
    signed URLs that expire."""
    by_url = {}
    targets = set()
    for entry in responses:
        if entry["method"] != "GET":
            continue
        by_url[entry["url"]] = entry
        if "location" in entry:
            targets.add(urllib.parse.urljoin(entry["url"], entry["location"]))

    def final_hash(url):
        seen = set()
        while url in by_url and url not in seen:
            seen.add(url)
            entry = by_url[url]
            if "hash" in entry:
                return entry["hash"]
            if "location" not in entry:
                return None
            url = urllib.parse.urljoin(url, entry["location"])
        return None

    files = {}
    paths = {}
    for url in by_url:
        if url in targets:
            continue
        file_hash = final_hash(url)
        if file_hash is None:
            continue
        path = url_path(url)
        if path in paths and paths[path] != url:
            raise RecordError(
                f"{paths[path]} and {url} differ only in their query, which the replay cannot tell apart"
            )
        paths[path] = url
        files[url] = {"path": path, "url": url, "mirrors": [], "hash": file_hash}
    return files


def command(entry, with_value):
    """The working directory, the arguments after the global options, and
    the values of the global options in `with_value`."""
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


def git_clones(entries):
    """The git clones of a git record, by directory: {url, ref,
    submodules}. ExternalProject and FetchContent clone with `git clone
    <options> <url> <dir>`, check out with `git checkout <ref>` in <dir>,
    and initialize submodules with `git submodule update`."""
    clones = {}
    for entry in entries:
        cwd, args, _ = command(entry, {"-C", "-c"})
        if not args:
            continue
        if args[0] == "clone" and len(args) >= 3:
            directory = os.path.normpath(os.path.join(cwd, args[-1]))
            clones[directory] = {"url": args[-2], "ref": None, "submodules": False}
        elif cwd in clones and args[0] == "checkout":
            refs = [a for a in args[1:] if not a.startswith("-")]
            if refs:
                clones[cwd]["ref"] = refs[0]
        elif cwd in clones and args[0] == "submodule" and "update" in args:
            clones[cwd]["submodules"] = True
    return clones


def hg_clones(entries):
    """The Mercurial clones of an hg record, by directory: {url, ref}, from
    `hg clone -U <url> <dir>` and the `hg update <tag>` in <dir>."""
    clones = {}
    for entry in entries:
        cwd, args, _ = command(entry, {"--cwd", "-R", "--repository", "--config"})
        if not args:
            continue
        if args[0] == "clone":
            positional = [a for a in args[1:] if not a.startswith("-")]
            if len(positional) >= 2:
                directory = os.path.normpath(os.path.join(cwd, positional[1]))
                clones[directory] = {"url": positional[0], "ref": ""}
        elif cwd in clones and args[0] in ("update", "up"):
            refs = [a for a in args[1:] if not a.startswith("-")]
            clones[cwd]["ref"] = refs[0] if refs else ""
    return clones


def svn_checkouts(entries):
    """The Subversion checkouts of an svn record: {url, ref, dir}, from
    `svn co <url> [-r<rev>] ... <dir>`, where ref is the -r value."""
    checkouts = []
    for entry in entries:
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
        if len(positional) < 2:
            raise RecordError(f"an svn checkout without a URL and a directory: {args}")
        checkouts.append({
            "url": positional[0],
            "ref": ref,
            "dir": os.path.normpath(os.path.join(cwd, positional[-1])),
        })
    return checkouts


def cvs_checkouts(entries, default_root):
    """The CVS checkouts of a cvs record: {root, module, tag, date, ref,
    dir}, from `cvs -d <root> co [-r<tag> | -D<date>] -d <dir> <module>`.
    ref is `r:<tag>`, `D:<date>` or empty, as vcs-shim.sh spells it."""
    checkouts = []
    for entry in entries:
        cwd, args, options = command(entry, {"-d", "-z", "-s", "-T", "-e"})
        if not args or args[0] not in ("co", "checkout"):
            continue
        tag = None
        date = None
        ref = ""
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
            raise RecordError(f"a cvs checkout without a module: {args}")
        checkouts.append({
            "root": options.get("-d", default_root),
            "module": module,
            "tag": tag,
            "date": date,
            "ref": ref,
            "dir": os.path.normpath(os.path.join(cwd, directory or module)),
        })
    return checkouts
