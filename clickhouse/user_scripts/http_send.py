#!/usr/bin/python3

import http.client
import json
import sys
from urllib.parse import urlparse


def send_request(url, method, params):
    parsed_url = urlparse(url)
    detail_url = parsed_url.path

    if method.upper() == "GET":
        detail_url = f"{parsed_url.path}?{parsed_url.query}"
        params = None
    elif isinstance(params, dict):
        params = json.dumps(params)

    # Create a connection object
    conn = http.client.HTTPConnection(parsed_url.netloc)

    # Send the request
    conn.request(method, detail_url, params.encode("utf-8"))

    # Get the response
    response = conn.getresponse()
    resp = response.read().decode()
    # Close the connection
    conn.close()
    return resp


if __name__ == "__main__":
    for line in sys.stdin:
        if line == "\n":
            break
        try:
            value = json.loads(line)
            url = value["url"]
            method = value["method"]
            params = value["params"]

            result = send_request(url, method, params)
            print(json.dumps({"result": result}), end="\n")

            sys.stdout.flush()
        except Exception as e:
            print(json.dumps({"result": str(e)}), end="\n")
            sys.stdout.flush()
