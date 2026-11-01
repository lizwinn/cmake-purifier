# SPDX-License-Identifier: MIT
#
# Checks records.py on sample records of each kind. The flake check
# `lock-records` runs it.
import sys

sys.path.insert(0, sys.argv[1])
import records

failures = []


def check(name, got, want):
    if got != want:
        failures.append(f"{name}: got {got!r}, want {want!r}")


def raises(name, function):
    try:
        function()
    except records.RecordError:
        return
    failures.append(f"{name}: no RecordError")


# A redirect counts as the file it leads to, under the URL the build asked
# for, and the signed target of the redirect is left out.
signed = "https://objects.example.com/blob?sig=abc"
files = records.file_artifacts([
    {"method": "GET", "url": "https://example.com/a.zip", "status": 302, "location": signed},
    {"method": "GET", "url": signed, "status": 200, "hash": "sha256-A"},
    {"method": "GET", "url": "https://example.com/b.h", "status": 200, "hash": "sha256-B"},
    {"method": "GET", "url": "https://example.com/missing", "status": 404},
    {"method": "POST", "url": "https://example.com/api", "status": 200, "hash": "sha256-C"},
])
check("files", sorted(files), ["https://example.com/a.zip", "https://example.com/b.h"])
check("redirect hash", files["https://example.com/a.zip"]["hash"], "sha256-A")
check("file path", files["https://example.com/b.h"]["path"], "https/example.com/b.h")
check("mirrors", files["https://example.com/b.h"]["mirrors"], [])

# A relative redirect resolves against the URL it came from.
relative = records.file_artifacts([
    {"method": "GET", "url": "https://example.com/dl/x", "status": 301, "location": "/files/x"},
    {"method": "GET", "url": "https://example.com/files/x", "status": 200, "hash": "sha256-X"},
])
check("relative redirect", sorted(relative), ["https://example.com/dl/x"])

raises("query clash", lambda: records.file_artifacts([
    {"method": "GET", "url": "https://example.com/f?v=1", "status": 200, "hash": "sha256-1"},
    {"method": "GET", "url": "https://example.com/f?v=2", "status": 200, "hash": "sha256-2"},
]))

# ExternalProject's git clone, checkout and submodule update.
git = records.git_clones([
    {"cwd": "/b/_deps", "args": ["--version"]},
    {"cwd": "/b/_deps", "args": ["clone", "--depth", "1", "--no-single-branch", "--config", "advice.detachedHead=false",
                                 "https://example.com/r.git", "r-src"]},
    {"cwd": "/b/_deps/r-src", "args": ["checkout", "v1", "--"]},
    {"cwd": "/b/_deps/r-src", "args": ["-c", "http.sslVerify=true", "submodule", "update", "--recursive", "--init"]},
    {"cwd": "/b/ep", "args": ["clone", "git@example.com:o/s.git", "s"]},
    {"cwd": "/b", "args": ["-C", "ep/s", "checkout", "main"]},
])
check("git clones", git, {
    "/b/_deps/r-src": {"url": "https://example.com/r.git", "ref": "v1", "submodules": True},
    "/b/ep/s": {"url": "git@example.com:o/s.git", "ref": "main", "submodules": False},
})

# ExternalProject's hg clone and update.
hg = records.hg_clones([
    {"cwd": "/b/src", "args": ["clone", "-U", "file:///repo/hg", "hglib"]},
    {"cwd": "/b/src/hglib", "args": ["update", "v1"]},
    {"cwd": "/b/src/hglib", "args": ["pull"]},
])
check("hg clones", hg, {"/b/src/hglib": {"url": "file:///repo/hg", "ref": "v1"}})

# ExternalProject's svn checkout, with and without a revision.
svn = records.svn_checkouts([
    {"cwd": "/b/src", "args": ["co", "https://svn.example.com/trunk", "-r1234", "--non-interactive", "lib"]},
    {"cwd": "/b/src", "args": ["checkout", "https://svn.example.com/other", "--non-interactive", "--username=u", "other"]},
    {"cwd": "/b/src/lib", "args": ["up", "-r1234", "--non-interactive"]},
])
check("svn checkouts", svn, [
    {"url": "https://svn.example.com/trunk", "ref": "1234", "dir": "/b/src/lib"},
    {"url": "https://svn.example.com/other", "ref": "", "dir": "/b/src/other"},
])
raises("svn without a directory", lambda: records.svn_checkouts([{"cwd": "/", "args": ["co", "url"]}]))

# ExternalProject's cvs checkout, with a tag, a date and neither.
cvs = records.cvs_checkouts([
    {"cwd": "/b/src", "args": ["-d", ":pserver:anon@cvs.example.com:/cvs", "-q", "co", "-rv1", "-d", "lib", "mod"]},
    {"cwd": "/b/src", "args": ["-d", "/local/cvs", "-q", "co", "-D", "2020-01-01", "-d", "dated", "mod"]},
    {"cwd": "/b/src", "args": ["-q", "checkout", "plain"]},
    {"cwd": "/b/src/lib", "args": ["-d", ":pserver:anon@cvs.example.com:/cvs", "-q", "up", "-dP", "-rv1"]},
], "/env/cvsroot")
check("cvs checkouts", cvs, [
    {"root": ":pserver:anon@cvs.example.com:/cvs", "module": "mod", "tag": "v1", "date": None, "ref": "r:v1", "dir": "/b/src/lib"},
    {"root": "/local/cvs", "module": "mod", "tag": None, "date": "2020-01-01", "ref": "D:2020-01-01", "dir": "/b/src/dated"},
    {"root": "/env/cvsroot", "module": "plain", "tag": None, "date": None, "ref": "", "dir": "/b/src/plain"},
])
raises("cvs without a module", lambda: records.cvs_checkouts([{"cwd": "/", "args": ["co", "-rv1"]}], ""))

for failure in failures:
    print(failure)
sys.exit(1 if failures else 0)
