#!/usr/bin/python3

import http.client
import json
import sys
from urllib.parse import urlparse


def send_request(url, token, subject, content, to, tp):
    parsed_url = urlparse(url)

    params = json.dumps(
        [
            {
                "Authorization": token,
                "subject": subject,
                "content": content,
                "to": to,
                "type": tp,
            }
        ]
    )

    # Create a connection object
    conn = http.client.HTTPConnection(parsed_url.netloc)

    # Send the request
    conn.request("POST", parsed_url.path, params.encode("utf-8"))

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
            token = value["token"]
            subject = value["subject"]
            content = value["content"]
            to = value["to"]
            tp = value["type"]

            result = send_request(url, token, subject, content, to, tp)
            print(json.dumps({"result": result}), end="\n")

            sys.stdout.flush()
        except Exception as e:
            print(json.dumps({"result": str(e)}), end="\n")
            sys.stdout.flush()
