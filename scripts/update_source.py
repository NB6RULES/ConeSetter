"""Adds a new build to source.json (AltStore / SideStore source format v2)."""
import argparse
import datetime as dt
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--version", required=True)
parser.add_argument("--build", required=True)
parser.add_argument("--size", required=True, type=int)
parser.add_argument("--url", required=True)
parser.add_argument("--notes", default="")
parser.add_argument("--source", default="source.json")
parser.add_argument("--bundle", default="com.nb6rules.conesetter")
args = parser.parse_args()

path = Path(args.source)
source = json.loads(path.read_text())
app = next(a for a in source["apps"] if a["bundleIdentifier"] == args.bundle)

date = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
entry = {
    "version": args.version,
    "buildVersion": str(args.build),
    "date": date,
    "localizedDescription": args.notes or f"Build {args.build}",
    "downloadURL": args.url,
    "size": args.size,
    "minOSVersion": "18.0",
}

versions = [v for v in app.get("versions", []) if v.get("buildVersion") != str(args.build)]
app["versions"] = ([entry] + versions)[:10]

# Legacy top-level fields for older AltStore / SideStore builds.
app["version"] = args.version
app["versionDate"] = date
app["versionDescription"] = entry["localizedDescription"]
app["downloadURL"] = args.url
app["size"] = args.size

path.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n")
print(f"source.json -> {args.version} ({args.build})")
