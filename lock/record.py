# SPDX-License-Identifier: MIT
#
# The mitmproxy addon of the lock run. It appends a JSON line per response
# to the file in PURIFIER_RECORD: the method, the URL and the status, the
# target of a redirect, and the SHA-256 of a successful GET's body.
import base64
import hashlib
import json
import os


class Record:
    def __init__(self):
        self.path = os.environ["PURIFIER_RECORD"]

    def response(self, flow):
        response = flow.response
        entry = {
            "method": flow.request.method,
            "url": flow.request.pretty_url,
            "status": response.status_code,
        }
        if 300 <= response.status_code < 400 and "location" in response.headers:
            entry["location"] = response.headers["location"]
        elif response.status_code == 200 and flow.request.method == "GET":
            digest = hashlib.sha256(response.content).digest()
            entry["hash"] = "sha256-" + base64.b64encode(digest).decode()
        with open(self.path, "a") as out:
            out.write(json.dumps(entry) + "\n")


addons = [Record()]
