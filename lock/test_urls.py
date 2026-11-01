# SPDX-License-Identifier: MIT
#
# Checks the URL rules of urls.py. The flake check `lock-urls` runs it.
import sys

sys.path.insert(0, sys.argv[1])
from urls import https_of, url_path

cases = [
    (url_path("https://github.com/a/b/releases/download/v1/x.zip?sig=1"), "https/github.com/a/b/releases/download/v1/x.zip"),
    (url_path("https://example.com:443/f"), "https/example.com/f"),
    (url_path("http://example.com:8080/f"), "http/example.com:8080/f"),
    (url_path("file:///nix/store/abc-repos/hg"), "file/nix/store/abc-repos/hg"),
    (https_of("git@github.com:owner/repo.git"), "https://github.com/owner/repo.git"),
    (https_of("ssh://git@gitlab.example.com:2222/group/repo.git"), "https://gitlab.example.com/group/repo.git"),
    (https_of("ssh://example.com/repo"), "https://example.com/repo"),
    (https_of("https://github.com/owner/repo.git"), None),
    (https_of("file:///nix/store/abc-repos/git"), None),
]
failed = [(got, want) for got, want in cases if got != want]
for got, want in failed:
    print(f"got {got!r}, want {want!r}")
sys.exit(1 if failed else 0)
