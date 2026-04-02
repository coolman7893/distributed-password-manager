#!/usr/bin/env python3
"""
Distributed Password Manager - Status Display
Shows IPs and health status of master and chunk servers using Rich library.
Probes actual service health via gcloud SSH (like the deploy script does).
"""

import os
import subprocess
import sys
from datetime import datetime
from typing import Dict, List, Tuple

try:
    from rich.console import Console
    from rich.table import Table
    from rich.panel import Panel
    from rich.text import Text
    from rich import box
except ImportError:
    print("Error: Rich library not found.")
    print("Install it with: pip install rich")
    sys.exit(1)


console = Console()


def get_gcp_status() -> Tuple[Dict, List[Dict]]:
    """Get master and chunk status from GCP using gcloud SSH health checks."""
    master = {"name": "master", "ip": "", "port": "9000", "status": "DOWN"}
    chunks = []

    gcp_project = os.environ.get("GCP_PROJECT", "")
    if not gcp_project:
        console.print("[yellow]Error: GCP_PROJECT environment variable not set[/yellow]")
        console.print("[dim]Set it with: export GCP_PROJECT=your-project-id[/dim]")
        return master, chunks

    vm_prefix = os.environ.get("VM_PREFIX", "pwm")

    try:
        # Fetch all instances with zone and IP info
        result = subprocess.run(
            f'gcloud compute instances list --project={gcp_project} --filter="name:{vm_prefix}*" --format="value(name,zone.basename(),networkInterfaces[0].accessConfigs[0].natIP)"',
            capture_output=True,
            text=True,
            timeout=15,
            shell=True,
        )

        if result.returncode != 0:
            console.print("[red]Error: Failed to list instances[/red]")
            if result.stderr:
                console.print(f"[dim]{result.stderr}[/dim]")
            return master, chunks

        # Parse instances and check health
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue

            parts = line.split()
            if len(parts) < 3:
                continue

            vm_name = parts[0]
            zone = parts[1]
            ip = parts[2] if parts[2] != "None" else "N/A"

            # Determine service name, port, and systemctl service
            if "master" in vm_name.lower():
                service_name = "master"
                port = "9000"
                systemctl_service = "pwm-master"
            elif "chunk1" in vm_name.lower():
                service_name = "chunk1"
                port = "9001"
                systemctl_service = "pwm-chunk"
            elif "chunk2" in vm_name.lower():
                service_name = "chunk2"
                port = "9002"
                systemctl_service = "pwm-chunk"
            elif "chunk3" in vm_name.lower():
                service_name = "chunk3"
                port = "9003"
                systemctl_service = "pwm-chunk"
            else:
                continue

            # Check health via SSH
            status = "DOWN"
            if ip != "N/A":
                try:
                    ssh_cmd = f'gcloud compute ssh {vm_name} --zone={zone} --project={gcp_project} --quiet --command="sudo systemctl is-active {systemctl_service}"'
                    ssh_result = subprocess.run(
                        ssh_cmd,
                        capture_output=True,
                        timeout=10,
                        shell=True,
                    )
                    if ssh_result.returncode == 0:
                        status = "UP"
                except (subprocess.TimeoutExpired, Exception):
                    status = "DOWN"

            # Add to appropriate list
            if service_name == "master":
                master["ip"] = ip
                master["status"] = status
            else:
                chunks.append(
                    {
                        "name": service_name,
                        "ip": ip,
                        "port": port,
                        "status": status,
                    }
                )

        # Sort chunks numerically
        chunks.sort(key=lambda x: int(x["name"].replace("chunk", "")))

    except subprocess.TimeoutExpired:
        console.print("[red]Error: gcloud command timed out[/red]")
    except Exception as e:
        console.print(f"[red]Error querying GCP: {e}[/red]")

    return master, chunks


def create_status_table(master: Dict, chunks: List[Dict]) -> Table:
    """Create a Rich table with master and chunk status."""
    table = Table(box=box.ROUNDED, show_header=True, header_style="bold cyan")

    table.add_column("Service", style="magenta", width=15)
    table.add_column("IP Address", style="yellow", width=20)
    table.add_column("Port", style="cyan", width=10)
    table.add_column("Status", width=12)

    # Add master row
    status_display = "[green]✓ UP[/green]" if master["status"] == "UP" else "[red]✗ DOWN[/red]"
    table.add_row(
        master["name"],
        master["ip"] or "N/A",
        master["port"],
        status_display,
    )

    # Add separator
    table.add_section()

    # Add chunk rows
    for chunk in chunks:
        status_display = "[green]✓ UP[/green]" if chunk["status"] == "UP" else "[red]✗ DOWN[/red]"
        table.add_row(
            chunk["name"],
            chunk["ip"],
            chunk["port"],
            status_display,
        )

    return table


def main():
    """Main function."""
    console.clear()
    header_text = Text("Distributed Password Manager - Status Check", justify="center")
    console.print(
        Panel(
            header_text,
            style="bold cyan",
            expand=False,
        )
    )
    console.print()

    gcp_project = os.environ.get("GCP_PROJECT", "")
    if gcp_project:
        console.print(f"[dim]Environment: [cyan]Google Cloud Platform[/cyan] ({gcp_project})[/dim]")
    else:
        console.print("[yellow]Warning: GCP_PROJECT not set[/yellow]")

    console.print()

    master, chunks = get_gcp_status()

    # Create and display the table
    table = create_status_table(master, chunks)
    console.print(table)

    console.print()
    console.print(f"[dim]Last updated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}[/dim]")

    # Summary
    up_count = sum(1 for chunk in chunks if chunk["status"] == "UP") + (1 if master["status"] == "UP" else 0)
    total_count = len(chunks) + 1

    if up_count == total_count:
        console.print(f"[green]All {total_count} services running[/green]")
    else:
        console.print(f"[yellow]{up_count}/{total_count} services running[/yellow]")

    console.print()


if __name__ == "__main__":
    main()
