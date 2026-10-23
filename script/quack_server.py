# /// script
# requires-python = ">=3.11"
# dependencies = ["duckdb>=1.5.5"]
# ///
"""Disposable in-memory server used only by the integration suite."""
import argparse
import json
import time
import tempfile
import signal
import duckdb

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--tls-port", type=int, required=True)
args = parser.parse_args()


def stop(_signum, _frame):
    raise SystemExit(0)


signal.signal(signal.SIGTERM, stop)
connection = duckdb.connect()
connection.execute(
    f"call quack_serve('quack:127.0.0.1:{args.port}', token='quack-ruby-test')"
)
if duckdb.__version__.startswith("1."):
    print(json.dumps({"ready": True, "version": duckdb.__version__}), flush=True)
    while True:
        time.sleep(1)

with tempfile.TemporaryDirectory() as directory:
    cursor = connection.execute("call quack_generate_keys(directory = ?)", [directory])
    keys = dict(zip([column[0] for column in cursor.description], cursor.fetchone()))
    connection.execute(
        f"call quack_serve('quack:127.0.0.1:{args.tls_port}', token='quack-ruby-test', "
        "disable_ssl=false, ssl_cert_file=?, ssl_key_file=?)",
        [keys["cert_file"], keys["key_file"]],
    )
    print(json.dumps({"ready": True, "version": duckdb.__version__, "fingerprint": keys["fingerprint"]}), flush=True)
    while True:
        time.sleep(1)
