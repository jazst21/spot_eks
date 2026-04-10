#!/usr/bin/env python3
"""Simulate EC2 Spot interruption by sending real-format EventBridge events.

Works in regions without AWS FIS. Triggers NTH/Karpenter to cordon+drain,
then optionally terminates the instance.

Usage:
  python3 simulate_spot_interruption.py                        # interactive
  python3 simulate_spot_interruption.py --node-name <name>     # target node
  python3 simulate_spot_interruption.py --event rebalance      # rebalance event
  python3 simulate_spot_interruption.py --dry-run              # event only, no terminate
"""

import argparse
import json
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone, timedelta

import boto3
from rich.console import Console
from rich.table import Table
from rich.live import Live
from rich.text import Text

console = Console()

EVENTS = {
    "interruption": {
        "detail-type": "EC2 Spot Instance Interruption Warning",
        "detail_fn": lambda iid: {"instance-id": iid, "instance-action": "terminate"},
    },
    "rebalance": {
        "detail-type": "EC2 Instance Rebalance Recommendation",
        "detail_fn": lambda iid: {"instance-id": iid},
    },
}


def kubectl_json(cmd):
    r = subprocess.run(["kubectl"] + cmd + ["-o", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"kubectl error: {r.stderr.strip()}")
    return json.loads(r.stdout)


def get_spot_nodes():
    return _get_nodes("eks.amazonaws.com/capacityType=SPOT")


def get_all_nodes():
    return _get_nodes(None)


def _get_nodes(label_selector):
    cmd = ["get", "nodes"]
    if label_selector:
        cmd += ["-l", label_selector]
    data = kubectl_json(cmd)
    nodes = []
    for n in data.get("items", []):
        iid = n["spec"].get("providerID", "").split("/")[-1]
        name = n["metadata"]["name"]
        zone = n["metadata"]["labels"].get("topology.kubernetes.io/zone", "?")
        itype = n["metadata"]["labels"].get("node.kubernetes.io/instance-type", "?")
        capacity = n["metadata"]["labels"].get("eks.amazonaws.com/capacityType", "?")
        wtype = n["metadata"]["labels"].get("workload-type", "?")
        pods = subprocess.run(
            ["kubectl", "get", "pods", "--all-namespaces", "--field-selector", f"spec.nodeName={name}",
             "--no-headers"], capture_output=True, text=True
        ).stdout.strip().count("\n") + 1
        nodes.append({"name": name, "instance_id": iid, "zone": zone, "type": itype,
                       "capacity": capacity, "workload_type": wtype, "pods": pods})
    return nodes


def pick_node(nodes):
    table = Table(title="Cluster Nodes", show_lines=True, border_style="cyan")
    table.add_column("#", justify="center")
    table.add_column("Node Name")
    table.add_column("Instance ID")
    table.add_column("AZ")
    table.add_column("Type")
    table.add_column("Capacity", justify="center")
    table.add_column("MNG Role", justify="center")
    table.add_column("Pods", justify="center")
    for i, n in enumerate(nodes):
        style = "" if n["capacity"] == "SPOT" else "dim"
        table.add_row(str(i), n["name"], n["instance_id"], n["zone"], n["type"],
                       n["capacity"], n["workload_type"], str(n["pods"]), style=style)
    console.print(table)
    while True:
        choice = console.input("\n[cyan]Select node #:[/] ")
        if choice.isdigit() and 0 <= int(choice) < len(nodes):
            return nodes[int(choice)]
        console.print("[red]Invalid selection[/]")


def validate_instance(ec2, instance_id):
    resp = ec2.describe_instances(InstanceIds=[instance_id])
    inst = resp["Reservations"][0]["Instances"][0]
    lifecycle = inst.get("InstanceLifecycle", "on-demand")
    az = inst["Placement"]["AvailabilityZone"]
    return az, lifecycle


def send_event(sqs_client, queue_url, event_type, instance_id, az, account, region):
    evt = EVENTS[event_type]
    detail = evt["detail_fn"](instance_id)
    # Build the full EventBridge-format message that NTH expects from SQS
    message = {
        "version": "0",
        "id": str(uuid.uuid4()),
        "detail-type": evt["detail-type"],
        "source": "aws.ec2",
        "account": account,
        "time": (datetime.now(timezone.utc) + timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "region": region,
        "resources": [f"arn:aws:ec2:{az}:instance/{instance_id}"],
        "detail": detail,
    }
    sqs_client.send_message(QueueUrl=queue_url, MessageBody=json.dumps(message))
    console.print(f"\n[green]✅ Sent to SQS:[/] {evt['detail-type']}")
    console.print(f"   Queue:    {queue_url}")
    console.print(f"   Instance: {instance_id}")
    console.print(f"   Detail:   {json.dumps(detail)}")


def wait_drain(node_name, timeout):
    console.print(f"\n[cyan]Waiting for drain (timeout {timeout}s)...[/]")
    start = time.time()
    cordoned = False
    while time.time() - start < timeout:
        # Check cordon
        r = subprocess.run(
            ["kubectl", "get", "node", node_name, "-o", "jsonpath={.spec.unschedulable}"],
            capture_output=True, text=True)
        if r.stdout.strip() == "true" and not cordoned:
            elapsed = int(time.time() - start)
            console.print(f"  [yellow]⏳ Node cordoned[/] ({elapsed}s)")
            cordoned = True

        # Check pod count (exclude DaemonSet pods — they can't be drained)
        r = subprocess.run(
            ["kubectl", "get", "pods", "--all-namespaces", "--field-selector",
             f"spec.nodeName={node_name}", "--no-headers",
             "-o", "jsonpath={range .items[*]}{.metadata.ownerReferences[0].kind} {end}"],
            capture_output=True, text=True)
        kinds = r.stdout.strip().split()
        pod_count = sum(1 for k in kinds if k != "DaemonSet")
        elapsed = int(time.time() - start)

        if cordoned and pod_count == 0:
            console.print(f"  [green]✅ Node drained[/] ({elapsed}s, 0 pods remaining)")
            return True

        status = "cordoned, draining" if cordoned else "waiting for cordon"
        console.print(f"  [{elapsed}s] {status} — {pod_count} pods remaining", end="\r")
        time.sleep(5)

    console.print(f"\n  [yellow]⚠ Drain timeout after {timeout}s[/]")
    return False


def terminate_instance(ec2, instance_id):
    console.print(f"\n[red]🔥 Terminating {instance_id}...[/]")
    ec2.terminate_instances(InstanceIds=[instance_id])
    console.print(f"[red]✅ Terminated[/]")


def wait_recovery(node_name, timeout=180):
    console.print(f"\n[cyan]Watching for recovery (timeout {timeout}s)...[/]")
    start = time.time()
    old_gone = False
    while time.time() - start < timeout:
        r = subprocess.run(["kubectl", "get", "nodes", "-l", "eks.amazonaws.com/capacityType=SPOT",
                            "--no-headers"], capture_output=True, text=True)
        lines = [l for l in r.stdout.strip().split("\n") if l.strip()]
        names = [l.split()[0] for l in lines]
        statuses = {l.split()[0]: l.split()[1] for l in lines}

        if node_name not in names:
            if not old_gone:
                console.print(f"  [yellow]Node {node_name} removed from cluster[/]")
                old_gone = True

        ready_new = [n for n in names if n != node_name and statuses.get(n) == "Ready"]
        elapsed = int(time.time() - start)

        if old_gone and ready_new:
            console.print(f"  [green]✅ Replacement node ready: {ready_new[0]}[/] ({elapsed}s)")
            return
        time.sleep(10)
    console.print(f"  [yellow]⚠ Recovery timeout[/]")


def check_spread():
    """Show pod topology spread per deployment across nodes and AZs."""
    from rich.panel import Panel
    # Build node map
    node_data = kubectl_json(["get", "nodes"])
    node_info = {}
    for n in node_data.get("items", []):
        name = n["metadata"]["name"]
        short = name.split(".")[0]
        az = n["metadata"]["labels"].get("topology.kubernetes.io/zone", "?")
        cap = n["metadata"]["labels"].get("eks.amazonaws.com/capacityType", "?")
        node_info[name] = {"short": short, "az": az, "capacity": cap}

    # Get pods from all namespaces (or bookinfo only if no --all-nodes context)
    pods = kubectl_json(["get", "pods", "--all-namespaces", "-l", "app"])
    deployments = {}
    for p in pods.get("items", []):
        labels = p["metadata"].get("labels", {})
        ns = p["metadata"].get("namespace", "?")
        app = labels.get("app", "?")
        ver = labels.get("version", "")
        dep = f"{ns}/{app}-{ver}" if ver else f"{ns}/{app}"
        node = p["spec"].get("nodeName", "?")
        info = node_info.get(node, {"short": node, "az": "?", "capacity": "?"})
        deployments.setdefault(dep, []).append(info)

    table = Table(show_lines=True, border_style="cyan", header_style="bold cyan")
    table.add_column("Deployment")
    table.add_column("Replicas", justify="center")
    table.add_column("Nodes")
    table.add_column("AZs")
    table.add_column("Capacity Mix", justify="center")
    table.add_column("Spread", justify="center")

    for dep in sorted(deployments):
        nodes = deployments[dep]
        node_names = sorted(set(f"{n['short']} ({n['capacity']})" for n in nodes))
        azs = sorted(set(n["az"] for n in nodes))
        caps = sorted(set(n["capacity"] for n in nodes))
        unique_nodes = len(set(n["short"] for n in nodes))
        unique_azs = len(azs)
        ok = unique_azs >= 2 or (unique_nodes >= 2 and len(nodes) > 1)
        icon = "[green]✅[/]" if ok else "[red]❌ single[/]"
        cap_str = " + ".join(f"[green]{c}[/]" if c == "SPOT" else f"[cyan]{c}[/]" for c in caps)
        table.add_row(
            dep,
            str(len(nodes)),
            "\n".join(node_names),
            "\n".join(azs),
            cap_str,
            icon,
        )

    console.print()
    console.print(Panel(table, title="[bold]Pod Topology Spread[/]", border_style="cyan"))
    console.print()


def main():
    parser = argparse.ArgumentParser(
        description="Simulate EC2 Spot interruption via SQS → NTH/Karpenter",
        epilog="""examples:
  %(prog)s                           interactive — pick a Spot node
  %(prog)s --all-nodes               show all nodes (system + workload)
  %(prog)s --dry-run                 send event only, don't terminate
  %(prog)s --event rebalance         send rebalance recommendation (advisory)
  %(prog)s --node-name ip-10-0-...   target specific node
  %(prog)s --wait 60 --dry-run       custom drain timeout
  %(prog)s --check-spread            show pod spread across nodes/AZs""",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--event", choices=["interruption", "rebalance"], default="interruption",
                        help="event type: interruption (2-min warning, terminates) or rebalance (advisory, no terminate) [default: interruption]")
    parser.add_argument("--node-name", default=None, help="target node by kubernetes node name")
    parser.add_argument("--instance-id", default=None, help="target node by EC2 instance ID")
    parser.add_argument("--wait", type=int, default=120, help="seconds to wait for drain [default: 120]")
    parser.add_argument("--dry-run", action="store_true", help="send SQS event only — do not terminate the instance")
    parser.add_argument("--all-nodes", action="store_true", help="show all nodes (system + workload), not just Spot")
    parser.add_argument("--region", default=None, help="AWS region (auto-detected from node AZ if omitted)")
    parser.add_argument("--queue-url", default=None, help="NTH/Karpenter SQS queue URL (auto-discovered if omitted)")
    parser.add_argument("--check-spread", action="store_true", help="show pod spread across nodes/AZs and exit")
    args = parser.parse_args()

    if args.check_spread:
        check_spread()
        return

    # Resolve region from node AZ or args
    if not args.region:
        nodes = get_all_nodes() if args.all_nodes else get_spot_nodes()
        if nodes:
            args.region = nodes[0]["zone"][:-1]
    region = args.region or "ap-southeast-3"
    ec2 = boto3.client("ec2", region_name=region)
    sqs = boto3.client("sqs", region_name=region)
    account = boto3.client("sts", region_name=region).get_caller_identity()["Account"]

    # Find NTH SQS queue
    queue_url = args.queue_url
    if not queue_url:
        # Try common NTH queue name patterns
        for prefix in ["eks-spot-asg-nth", "eks-spot-karpenter"]:
            try:
                queue_url = sqs.get_queue_url(QueueName=prefix)["QueueUrl"]
                break
            except Exception:
                continue
    if not queue_url:
        sys.exit("Could not find NTH/Karpenter SQS queue. Use --queue-url to specify.")

    # Resolve target
    if not args.instance_id and not args.node_name:
        # Interactive mode — nodes already fetched for region detection
        if not nodes:
            sys.exit("No Spot nodes found in cluster")
        node = pick_node(nodes)
        instance_id, node_name = node["instance_id"], node["name"]
        az, lifecycle = validate_instance(ec2, instance_id)
    elif args.instance_id:
        instance_id = args.instance_id
        az, lifecycle = validate_instance(ec2, instance_id)
        # Find node name
        nodes = get_spot_nodes()
        node = next((n for n in nodes if n["instance_id"] == instance_id), None)
        node_name = node["name"] if node else None
    elif args.node_name:
        if not nodes:
            nodes = get_spot_nodes()
        node = next((n for n in nodes if n["name"] == args.node_name), None)
        if not node:
            sys.exit(f"Node {args.node_name} not found among Spot nodes")
        instance_id, node_name = node["instance_id"], node["name"]
        az, lifecycle = validate_instance(ec2, instance_id)

    console.print(f"\n[bold]Target:[/] {node_name} ({instance_id}) in {az}")
    console.print(f"[bold]Event:[/]  {args.event}")
    console.print(f"[bold]Lifecycle:[/] {lifecycle}")
    if lifecycle != "spot":
        console.print("[yellow]⚠ This is NOT a Spot instance — simulating interruption on On-Demand node[/]")
    if args.dry_run:
        console.print("[yellow]Mode:   DRY RUN (no termination)[/]")

    # Send event directly to SQS (can't use PutEvents with source "aws.ec2")
    send_event(sqs, queue_url, args.event, instance_id, az, account, region)

    # Wait for drain
    if node_name:
        drained = wait_drain(node_name, args.wait)
    else:
        console.print("[yellow]Node name unknown, skipping drain watch[/]")
        drained = False

    # Terminate (interruption only, not dry-run)
    if args.event == "interruption" and not args.dry_run:
        terminate_instance(ec2, instance_id)
        if node_name:
            wait_recovery(node_name)
    elif args.event == "rebalance":
        console.print("\n[cyan]Rebalance is advisory — not terminating. Observe NTH/Karpenter behavior.[/]")
    elif args.dry_run:
        console.print("\n[cyan]Dry run complete — event sent, no termination.[/]")
        if node_name:
            console.print(f"[cyan]Uncordoning {node_name}...[/]")
            subprocess.run(["kubectl", "uncordon", node_name], capture_output=True)
            console.print(f"[green]✅ Node uncordoned[/]")

    console.print("\n[bold green]Done.[/]")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        console.print("\n[yellow]Interrupted.[/]")
        sys.exit(130)
