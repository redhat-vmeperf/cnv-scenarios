#!/usr/bin/env python3
"""
log-indexer.py - Parse kube-burner and validation logs and bulk-index to Elasticsearch.

Parses two log formats:
  1. kube-burner Logrus:  time="2026-03-16 23:44:00" level=info msg="..."
  2. validation log:      [2026-03-16T23:48:23+02:00] [phase] STATUS: message

Each line becomes a JSON document indexed into the cnv-logs ES index.

Usage:
  log-indexer.py --uuid UUID --test-name NAME --es-server URL --results-dir DIR
"""

import argparse
import json
import os
import re
import sys
import urllib.request

LOGRUS_RE = re.compile(
    r'time="(?P<ts>[^"]+)"\s+level=(?P<level>\w+)\s+msg="(?P<msg>.*?)"(?:\s+|$)'
)

VALIDATION_RE = re.compile(
    r'\[(?P<ts>[^\]]+)\]\s+'
    r'(?:\[(?P<phase>[^\]]+)\]\s+)?'
    r'(?:={4,}\s+VALIDATION\s+(?P<boundary>START|END):\s*(?P<label>.+?)\s*={4,}|'
    r'(?P<status>PASS|FAIL|SKIP):\s*(?P<msg>.*))'
)


def parse_kube_burner_log(filepath, uuid, test_name):
    """Parse kube-burner.log into structured documents."""
    docs = []
    if not os.path.isfile(filepath):
        return docs
    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            m = LOGRUS_RE.match(line)
            if m:
                ts = m.group("ts").replace(" ", "T") + "Z"
                docs.append({
                    "@timestamp": ts,
                    "level": m.group("level"),
                    "message": m.group("msg"),
                    "source": "kube-burner",
                    "uuid": uuid,
                    "testName": test_name,
                    "metricName": "log",
                })
            else:
                docs.append({
                    "@timestamp": docs[-1]["@timestamp"] if docs else "1970-01-01T00:00:00Z",
                    "level": "raw",
                    "message": line,
                    "source": "kube-burner",
                    "uuid": uuid,
                    "testName": test_name,
                    "metricName": "log",
                })
    return docs


def parse_validation_log(filepath, uuid, test_name):
    """Parse validation.log into structured documents."""
    docs = []
    if not os.path.isfile(filepath):
        return docs
    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            m = VALIDATION_RE.match(line)
            if m:
                ts = m.group("ts")
                if m.group("boundary"):
                    msg = f"VALIDATION {m.group('boundary')}: {m.group('label')}"
                    level = "info"
                elif m.group("status"):
                    status = m.group("status")
                    msg = f"[{m.group('phase')}] {status}: {m.group('msg')}"
                    level = "error" if status == "FAIL" else "info"
                else:
                    msg = line
                    level = "info"
                docs.append({
                    "@timestamp": ts,
                    "level": level,
                    "message": msg,
                    "source": "validation",
                    "uuid": uuid,
                    "testName": test_name,
                    "metricName": "log",
                })
            else:
                docs.append({
                    "@timestamp": docs[-1]["@timestamp"] if docs else "1970-01-01T00:00:00Z",
                    "level": "info",
                    "message": line,
                    "source": "validation",
                    "uuid": uuid,
                    "testName": test_name,
                    "metricName": "log",
                })
    return docs


def bulk_index(es_server, index, docs):
    """Bulk index documents to Elasticsearch."""
    if not docs:
        print(f"log-indexer: No documents to index for {index}")
        return 0

    bulk_body = ""
    for doc in docs:
        action = json.dumps({"index": {"_index": index}})
        body = json.dumps(doc)
        bulk_body += action + "\n" + body + "\n"

    url = f"{es_server}/_bulk"
    req = urllib.request.Request(
        url,
        data=bulk_body.encode("utf-8"),
        headers={"Content-Type": "application/x-ndjson"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read())
            errors = result.get("errors", False)
            if errors:
                err_items = [
                    i for i in result.get("items", [])
                    if "error" in i.get("index", {})
                ]
                print(f"log-indexer: WARNING: {len(err_items)} bulk errors out of {len(docs)} docs")
                if err_items:
                    print(f"log-indexer: First error: {json.dumps(err_items[0])}")
            else:
                print(f"log-indexer: Indexed {len(docs)} documents to {index}")
            return len(docs)
    except Exception as e:
        print(f"log-indexer: ERROR: Failed to bulk index to {es_server}: {e}")
        return 0


def find_validation_logs(results_dir):
    """Find all validation.log files in the results directory."""
    logs = []
    for root, dirs, files in os.walk(results_dir):
        for f in files:
            if f == "validation.log":
                logs.append(os.path.join(root, f))
    return logs


def main():
    parser = argparse.ArgumentParser(description="Index kube-burner and validation logs to Elasticsearch")
    parser.add_argument("--uuid", required=True, help="Run UUID")
    parser.add_argument("--test-name", required=True, help="Test name")
    parser.add_argument("--es-server", required=True, help="Elasticsearch server URL")
    parser.add_argument("--results-dir", required=True, help="Results directory path")
    parser.add_argument("--index", default="cnv-logs", help="ES index name (default: cnv-logs)")
    args = parser.parse_args()

    all_docs = []

    kb_log = os.path.join(args.results_dir, "kube-burner.log")
    if os.path.isfile(kb_log):
        docs = parse_kube_burner_log(kb_log, args.uuid, args.test_name)
        print(f"log-indexer: Parsed {len(docs)} lines from kube-burner.log")
        all_docs.extend(docs)
    else:
        print(f"log-indexer: kube-burner.log not found at {kb_log}")

    val_logs = find_validation_logs(args.results_dir)
    for vl in val_logs:
        docs = parse_validation_log(vl, args.uuid, args.test_name)
        print(f"log-indexer: Parsed {len(docs)} lines from {os.path.basename(vl)}")
        all_docs.extend(docs)

    if not val_logs:
        print("log-indexer: No validation.log files found")

    total = bulk_index(args.es_server, args.index, all_docs)
    print(f"log-indexer: Done. Total indexed: {total}")

    return 0 if total > 0 or not all_docs else 1


if __name__ == "__main__":
    sys.exit(main())
