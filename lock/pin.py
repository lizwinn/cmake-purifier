# SPDX-License-Identifier: MIT
"""Runs a version-control command of the lock run with the checkouts that
the lockfile already holds kept at their locked revisions.

    python3 -I pin.py <tool> <pins.json> <real tool> <count> <extra>... -- <args>...

<tool> is git, hg, svn or cvs. <pins.json> is a list of
{tool, repo, ref, rev}, one per locked checkout whose ref moves: the
commit of a git branch, the node of an hg update, the revision of an svn
checkout at HEAD, and the date of a CVS checkout without a tag. The
<count> <extra> arguments go to the real tool before <args>, as the
wrapper's own options. `cmake-purifier lock` passes every pin, so a relock
keeps what the lockfile resolved; `cmake-purifier update` leaves out the
pins of what it updates.

A git pin applies after a clone or a fetch of the repository: the
remote-tracking branch of the ref, and a local branch of that name,
point at the locked commit, which a shallow clone fetches when it lacks
it. The other tools get the locked revision added to their checkout and
update commands.
"""

import json
import os
import subprocess
import sys

tool, pins_file, real, count, *rest = sys.argv[1:]
count = int(count)
extra, rest = rest[:count], rest[count:]
assert rest and rest[0] == "--", "pin.py: the arguments must follow --"
args = rest[1:]

with open(pins_file) as f:
    pins = [p for p in json.load(f) if p["tool"] == tool]


def run(*command, cwd=None):
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False)


def split_global(args, with_value):
    """The global options and the rest, from the first subcommand on."""
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in with_value else 1
    return args[:i], args[i:]


def exec_real(arguments):
    os.execv(real, [real, *extra, *arguments])


if not pins:
    exec_real(args)

if tool == "git":
    global_options, command = split_global(args, {"-C", "-c", "--git-dir", "--work-tree"})
    cwd = os.getcwd()
    for i, option in enumerate(global_options):
        if option == "-C":
            cwd = os.path.join(cwd, global_options[i + 1])
    status = subprocess.run([real, *extra, *args], check=False).returncode
    if status != 0 or not command or command[0] not in ("clone", "fetch", "pull"):
        sys.exit(status)
    directory = cwd
    if command[0] == "clone":
        positional = []
        i = 1
        while i < len(command):
            if command[i] in ("-o", "--origin", "-b", "--branch", "--depth", "-c", "--config",
                              "--reference", "--template", "-j", "--jobs", "-u", "--upload-pack",
                              "--separate-git-dir", "--filter", "--shallow-since", "--shallow-exclude"):
                i += 2
            elif command[i].startswith("-"):
                i += 1
            else:
                positional.append(command[i])
                i += 1
        url = positional[0]
        name = positional[1] if len(positional) > 1 else os.path.basename(url.rstrip("/")).removesuffix(".git")
        directory = os.path.join(cwd, name)
    git = [real, "-C", directory]
    for remote in run(*git, "remote").stdout.split():
        url = run(*git, "remote", "get-url", remote).stdout.strip()
        for pin in pins:
            if pin["repo"] != url:
                continue
            ref, rev = pin["ref"], pin["rev"]
            # A tag or a commit does not move; only a branch has a pin to
            # apply.
            if ref == rev or run(*git, "rev-parse", "--verify", "--quiet", f"refs/tags/{ref}").returncode == 0:
                continue
            if run(*git, "cat-file", "-e", f"{rev}^{{commit}}").returncode != 0:
                fetched = run(*git, "fetch", "--depth", "1", remote, rev)
                if fetched.returncode != 0:
                    sys.exit(f"cmake-purifier: could not fetch the locked commit {rev} of {ref} from {url}:\n{fetched.stderr}")
            run(*git, "update-ref", f"refs/remotes/{remote}/{ref}", rev)
            if run(*git, "rev-parse", "--verify", "--quiet", f"refs/heads/{ref}").returncode == 0:
                run(*git, "update-ref", f"refs/heads/{ref}", rev)
    sys.exit(0)

if tool == "hg":
    global_options, command = split_global(args, {"--cwd", "-R", "--repository", "--config"})
    if command and command[0] in ("update", "up", "checkout", "co"):
        cwd = os.getcwd()
        for i, option in enumerate(global_options):
            if option in ("--cwd", "-R", "--repository"):
                cwd = os.path.join(cwd, global_options[i + 1])
        url = run(real, *extra, "--cwd", cwd, "paths", "default").stdout.strip()
        refs = [a for a in command[1:] if not a.startswith("-")]
        ref = refs[0] if refs else ""
        for pin in pins:
            if pin["repo"] == url and pin["ref"] == ref:
                kept = [a for a in command[1:] if a != ref or not refs]
                exec_real([*global_options, command[0], *kept, "-r", pin["rev"]])
    exec_real(args)

if tool == "svn":
    if args and args[0] in ("co", "checkout", "up", "update") and not any(a.startswith("-r") for a in args[1:]):
        if args[0] in ("co", "checkout"):
            positional = [a for a in args[1:] if not a.startswith("-")]
            url = positional[0] if positional else ""
        else:
            targets = [a for a in args[1:] if not a.startswith("-")]
            url = run(real, *extra, "info", "--show-item", "url", *(targets[:1] or ["."])).stdout.strip()
        for pin in pins:
            if pin["repo"] == url and pin["ref"] in ("", "HEAD"):
                exec_real([args[0], "-r", str(pin["rev"]), *args[1:]])
    exec_real(args)

if tool == "cvs":
    global_options, command = split_global(args, {"-d", "-z", "-s", "-T", "-e"})
    if command and command[0] in ("co", "checkout", "up", "update") and not any(
        a[:2] in ("-r", "-D", "-A") for a in command[1:]
    ):
        root = None
        for i, option in enumerate(global_options):
            if option == "-d":
                root = global_options[i + 1]
            elif option.startswith("-d") and len(option) > 2:
                root = option[2:]
        if command[0] in ("co", "checkout"):
            modules = []
            i = 1
            while i < len(command):
                if command[i] in ("-d", "-j", "-k"):
                    i += 2
                elif command[i].startswith("-"):
                    i += 1
                else:
                    modules.append(command[i])
                    i += 1
            module = modules[0] if modules else ""
        else:
            def read(name):
                try:
                    with open(os.path.join("CVS", name)) as f:
                        return f.read().strip()
                except OSError:
                    return ""
            root = root or read("Root")
            module = read("Repository")
        root = root or os.environ.get("CVSROOT", "")
        for pin in pins:
            if pin["repo"] == f"{root} {module}" and pin["ref"] == "":
                exec_real([*global_options, command[0], "-D", pin["rev"], *command[1:]])
    exec_real(args)

exec_real(args)
