# SPDX-License-Identifier: MIT
#
# The URL rules of the lock run, which assemble.py uses and test_urls.py
# checks.
import re
import urllib.parse


def url_path(url):
    """The path mitm-cache replays a URL from: <scheme>/<host>/<path>."""
    parts = urllib.parse.urlsplit(url)
    host = parts.hostname or ""
    if parts.port and not (parts.scheme == "https" and parts.port == 443):
        host = f"{host}:{parts.port}"
    components = [c for c in parts.path.split("/") if c]
    return "/".join(c for c in [parts.scheme, host, *components] if c)


# `ssh://[user@]host[:port]/path` and the scp form `user@host:path`.
SSH_URL = re.compile(r"^ssh://(?:[^@/]+@)?([^:/]+)(?::\d+)?/(.+)$")
SCP_URL = re.compile(r"^[^@/:]+@([^:/]+):(?!/)(.+)$")


def https_of(url):
    """The HTTPS URL of the same repository on the same host, for an SSH
    URL; None for any other URL."""
    found = SSH_URL.match(url) or SCP_URL.match(url)
    if found is None:
        return None
    host, path = found.groups()
    return f"https://{host}/{path.lstrip('/')}"
