#!/usr/bin/env python3
"""Spot Readiness Checklist — queries a live cluster via kubectl.

Mirrors the Kubecost Spot Checklist checks:
  1. Controller Type (Deployment vs StatefulSet)
  2. Replica Count (>1)
  3. Local Storage (emptyDir)
  4. Pod Disruption Budget (minAvail/replicas > 0.5)
  5. Rolling Update Strategy (Deployment-only, threshold 0.9)
  6. Manual annotation override (spot.kubecost.com/spot-ready)

Usage:
  python3 spot_readiness.py                  # all namespaces
  python3 spot_readiness.py -n bookinfo      # single namespace
  python3 spot_readiness.py --json           # JSON output
"""

import argparse
import json
import math
import subprocess
import sys

# ── colours ──
G = "\033[32m"; R = "\033[31m"; Y = "\033[33m"; C = "\033[36m"; Z = "\033[0m"
PASS = f"{G}PASS{Z}"; FAIL = f"{R}FAIL{Z}"

SPOT_ANNOTATION = "spot.kubecost.com/spot-ready"


def kubectl_json(resource, namespace=None):
    cmd = ["kubectl", "get", resource, "-o", "json"]
    cmd += ["-n", namespace] if namespace else ["--all-namespaces"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"kubectl error: {r.stderr.strip()}")
    return json.loads(r.stdout).get("items", [])


def fetch_pdbs(namespace):
    pdbs = []
    for p in kubectl_json("pdb", namespace):
        sel = p.get("spec", {}).get("selector", {}).get("matchLabels", {})
        spec = p["spec"]
        entry = {"namespace": p["metadata"]["namespace"], "labels": sel}
        if "minAvailable" in spec:
            entry["mode"], entry["val"] = "min", spec["minAvailable"]
        elif "maxUnavailable" in spec:
            entry["mode"], entry["val"] = "max", spec["maxUnavailable"]
        else:
            continue
        pdbs.append(entry)
    return pdbs


def find_pdb(pdbs, namespace, pod_labels):
    """Find PDB whose matchLabels are a subset of the deployment's pod labels."""
    for p in pdbs:
        if p["namespace"] != namespace:
            continue
        if all(pod_labels.get(k) == v for k, v in p["labels"].items()):
            return (p["mode"], p["val"])
    return None


def fetch_ns_annotations(namespace):
    cmd = ["kubectl", "get", "ns", "-o", "json"]
    if namespace:
        cmd = ["kubectl", "get", "ns", namespace, "-o", "json"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        return {}
    data = json.loads(r.stdout)
    items = data.get("items", [data]) if "items" not in data else data["items"]
    return {
        ns["metadata"]["name"]: ns["metadata"].get("annotations", {})
        for ns in items
    }


def pdb_min_available(pdb_entry, replicas):
    mode, val = pdb_entry
    if isinstance(val, str) and val.endswith("%"):
        pct = int(val.rstrip("%"))
        v = math.floor(replicas * pct / 100) if mode == "max" else math.ceil(replicas * pct / 100)
    else:
        v = int(val)
    return v if mode == "min" else replicas - v


def check_workload(item, pdbs, ns_annotations):
    kind = item["kind"]
    meta = item["metadata"]
    spec = item["spec"]
    name = meta["name"]
    ns = meta["namespace"]
    replicas = spec.get("replicas", 1)
    annotations = meta.get("annotations", {})
    tpl = spec.get("template", {})
    volumes = tpl.get("spec", {}).get("volumes", [])

    checks = []  # list of (name, passed:bool, detail, reason|None)

    # 1. Controller type
    if kind == "Deployment":
        checks.append(("Controller Type", True, "Deployment (stateless)", None))
    else:
        checks.append(("Controller Type", False, f"{kind} (stateful)",
                        f"{kind} — risk of data loss on Spot"))

    # 2. Replica count
    if replicas > 1:
        checks.append(("Replica Count", True, f"{replicas} > 1", None))
    else:
        checks.append(("Replica Count", False, f"{replicas} (single replica)",
                        "Single replica — no redundancy during interruption"))

    # 3. Local storage
    has_emptydir = any("emptyDir" in v for v in volumes)
    if has_emptydir:
        checks.append(("Local Storage (emptyDir)", False, "emptyDir found",
                        "emptyDir volume — data loss risk on preemption"))
    else:
        checks.append(("Local Storage (emptyDir)", True, "none", None))

    # 4. PDB
    pod_labels = tpl.get("metadata", {}).get("labels", {})
    pdb_entry = find_pdb(pdbs, ns, pod_labels)
    if pdb_entry:
        min_a = pdb_min_available(pdb_entry, replicas)
        ratio = min_a / replicas if replicas else 0
        if ratio > 0.5:
            checks.append(("Pod Disruption Budget", False,
                           f"{min_a}/{replicas}",
                           f"PDB ratio {ratio:.2f} > 0.5 — high availability requirement"))
        else:
            checks.append(("Pod Disruption Budget", True,
                           f"{min_a}/{replicas}", None))
    else:
        checks.append(("Pod Disruption Budget", True, "0/{0}".format(replicas), None))

    # 5. Rolling Update Strategy (Deployment only)
    if kind == "Deployment":
        strategy = spec.get("strategy", {})
        stype = strategy.get("type", "RollingUpdate")
        if stype == "Recreate":
            checks.append(("Rolling Update Strategy", False, "Recreate (full downtime)",
                           "Recreate strategy — all pods killed at once"))
        else:
            ru = strategy.get("rollingUpdate", {})
            max_unavail = ru.get("maxUnavailable", "25%")
            if isinstance(max_unavail, str) and max_unavail.endswith("%"):
                pct = int(max_unavail.rstrip("%"))
                unavail_int = int(replicas * pct / 100)
            else:
                unavail_int = int(max_unavail)
            min_a = replicas - unavail_int
            ratio = min_a / replicas if replicas else 0
            if ratio > 0.9:
                checks.append(("Rolling Update Strategy", False,
                               f"{min_a}/{replicas}",
                               f"RUS ratio {ratio:.2f} > 0.9 — very tight update budget"))
            else:
                checks.append(("Rolling Update Strategy", True,
                               f"{min_a}/{replicas}", None))

    # 6. Manual annotation override (controller or namespace level)
    override = annotations.get(SPOT_ANNOTATION,
                               ns_annotations.get(ns, {}).get(SPOT_ANNOTATION))
    if override is not None:
        forced = str(override).lower() == "true"
        if forced:
            checks.append(("Manual Annotation Override", True, "spot-ready=true (forced)", None))
            # override: mark all passed
            checks = [(n, True, d, None) for n, _, d, _ in checks]
        else:
            checks.append(("Manual Annotation Override", False, "spot-ready=false (forced)",
                           "Manual override: spot-ready=false"))
            checks = [(n, False, d, r) for n, _, d, r in checks]
    else:
        checks.append(("Manual Annotation Override", None, "not set", None))

    passed = all(c[1] for c in checks if c[1] is not None)
    return {
        "kind": kind, "name": name, "namespace": ns,
        "replicas": replicas, "spot_ready": passed, "checks": checks,
    }


def _icon(val):
    if val is None: return "—"
    return "✅" if val else "❌"


def _check_map(checks):
    m = {}
    for name, passed, detail, _ in checks:
        if "Controller Type" in name: m["type"] = passed
        elif "Replica" in name: m["replicas"] = passed
        elif "Local" in name: m["storage"] = passed
        elif "Disruption" in name: m["pdb"] = passed
        elif "Rolling" in name: m["rus"] = passed
        elif "Annotation" in name: m["override"] = passed
    return m


def _pdb_detail(checks):
    for name, _, detail, _ in checks:
        if "Disruption" in name:
            return detail
    return "—"


def _rus_detail(checks):
    for name, _, detail, _ in checks:
        if "Rolling" in name:
            return detail
    return "—"


def _rich_icon(val):
    if val is None: return "[dim]—[/]"
    return "[green]✅[/]" if val else "[red]❌[/]"


def print_report(results):
    from rich.console import Console
    from rich.table import Table
    from rich.panel import Panel

    ready = sum(1 for r in results if r["spot_ready"])
    not_ready = len(results) - ready
    console = Console()

    table = Table(show_lines=True, border_style="cyan", header_style="bold cyan")
    table.add_column("Readiness", justify="center")
    table.add_column("Controller")
    table.add_column("Type", justify="center")
    table.add_column("Replicas", justify="center")
    table.add_column("Storage", justify="center")
    table.add_column("PDB", justify="center")
    table.add_column("Rolling Update", justify="center")
    table.add_column("NS Override", justify="center")
    table.add_column("Ctrl Override", justify="center")

    for r in results:
        cm = _check_map(r["checks"])
        rus = _rus_detail(r["checks"])
        pdb = _pdb_detail(r["checks"])
        rd = "[green bold]✅ Ready[/]" if r["spot_ready"] else "[red bold]❌ Not Ready[/]"
        style = "" if r["spot_ready"] else "on #1a0000"
        table.add_row(
            rd,
            f"[dim]{r['namespace']}:[/]\n[bold]{r['name']}[/]",
            _rich_icon(cm.get("type")),
            _rich_icon(cm.get("replicas")),
            _rich_icon(cm.get("storage")),
            f"{_rich_icon(cm.get('pdb'))} {pdb}",
            f"{_rich_icon(cm.get('rus'))} {rus}",
            _rich_icon(cm.get("override")),
            _rich_icon(cm.get("override")),
            style=style,
        )

    console.print()
    console.print(Panel(table, title="[bold]Spot Readiness Checklist[/]",
                        subtitle=f"[green]Ready: {ready}[/] │ [red]Not Ready: {not_ready}[/] │ Total: {len(results)}",
                        border_style="cyan"))
    console.print()


def print_csv(results, filename="spot_readiness.csv"):
    import csv
    rows = [["Readiness","Controller","Controller Type","Replicas","Local Storage","Controller PDB","Rolling Update","NS Annotation Override","Controller Annotation Override"]]
    for r in results:
        cm = _check_map(r["checks"])
        rus = _rus_detail(r["checks"])
        pdb = _pdb_detail(r["checks"])
        label = f"{r['namespace']}:{r['name']}"
        rd = "Spot Ready" if r["spot_ready"] else "Not Ready"
        rows.append([rd, label, _icon(cm.get('type')), _icon(cm.get('replicas')), _icon(cm.get('storage')), f"{_icon(cm.get('pdb'))} {pdb}", f"{_icon(cm.get('rus'))} {rus}", _icon(cm.get('override')), _icon(cm.get('override'))])
    with open(filename, "w", newline="") as f:
        csv.writer(f).writerows(rows)
    print(f"Written to {filename}")


def main():
    parser = argparse.ArgumentParser(description="Spot Readiness Checklist (live cluster)")
    parser.add_argument("-n", "--namespace", "--ns", default=None, help="namespace (default: all)")
    parser.add_argument("--json", action="store_true", help="JSON output")
    parser.add_argument("--csv", nargs="?", const="spot_readiness.csv", default=None, help="output to CSV file (default: spot_readiness.csv)")
    args = parser.parse_args()

    deployments = kubectl_json("deployments", args.namespace)
    statefulsets = kubectl_json("statefulsets", args.namespace)
    pdbs = fetch_pdbs(args.namespace)
    ns_annot = fetch_ns_annotations(args.namespace)

    results = [check_workload(w, pdbs, ns_annot) for w in deployments + statefulsets]

    if args.json:
        out = [
            {k: v for k, v in r.items() if k != "checks"} |
            {"checks": [{
                "name": c[0], "passed": c[1], "detail": c[2], "reason": c[3]
            } for c in r["checks"]]}
            for r in results
        ]
        print(json.dumps(out, indent=2))
    elif args.csv:
        print_csv(results, args.csv)
    else:
        print_report(results)


if __name__ == "__main__":
    main()
