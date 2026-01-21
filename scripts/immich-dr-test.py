#!/usr/bin/env python3
"""Immich Disaster Recovery Test Script.

A Python implementation of the Immich DR test workflow with automatic
PostgreSQL dump format detection and restoration.
"""

import argparse
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Optional


class DumpFormat(Enum):
    """PostgreSQL dump formats."""
    PLAIN_SQL = "plain"
    CUSTOM = "custom"
    DIRECTORY = "directory"


class Colors:
    """ANSI color codes for terminal output."""
    RED = "\033[0;31m"
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    CYAN = "\033[0;36m"
    NC = "\033[0m"  # No Color


@dataclass
class DrConfig:
    """Configuration for the DR test."""
    restic_repo: str
    restore_dir: Path
    snapshot_id: str
    photo_path: Optional[Path] = None
    sql_dump: Optional[Path] = None


def print_error(msg: str) -> None:
    """Print error message in red."""
    print(f"{Colors.RED}ERROR: {msg}{Colors.NC}", file=sys.stderr)


def print_success(msg: str) -> None:
    """Print success message in green."""
    print(f"{Colors.GREEN}{msg}{Colors.NC}")


def print_info(msg: str) -> None:
    """Print info message in cyan."""
    print(f"{Colors.CYAN}{msg}{Colors.NC}")


def print_warning(msg: str) -> None:
    """Print warning message in yellow."""
    print(f"{Colors.YELLOW}{msg}{Colors.NC}")


class FormatDetector:
    """Detects PostgreSQL dump format from file."""

    PGDMP_MAGIC = b"PGDMP"

    @classmethod
    def detect(cls, dump_path: Path) -> DumpFormat:
        """Detect the format of a PostgreSQL dump.

        Args:
            dump_path: Path to the dump file or directory.

        Returns:
            The detected DumpFormat.
        """
        if dump_path.is_dir():
            return DumpFormat.DIRECTORY

        # Check magic bytes (most reliable for custom format)
        try:
            with open(dump_path, "rb") as f:
                magic = f.read(5)
                if magic == cls.PGDMP_MAGIC:
                    return DumpFormat.CUSTOM
        except (IOError, OSError):
            pass

        # Fall back to extension-based detection
        suffix = dump_path.suffix.lower()
        if suffix in (".dump", ".pgdump"):
            return DumpFormat.CUSTOM

        return DumpFormat.PLAIN_SQL


class ResticOperations:
    """Handles restic backup operations."""

    def __init__(self, repo: str):
        self.repo = repo

    def check_password(self) -> None:
        """Check if RESTIC_PASSWORD is set, prompt if not."""
        if not os.environ.get("RESTIC_PASSWORD"):
            print_warning("RESTIC_PASSWORD not set")
            import getpass
            password = getpass.getpass("Enter restic repository password: ")
            os.environ["RESTIC_PASSWORD"] = password

    def list_snapshots(self) -> bool:
        """List available snapshots with tag 'immich'."""
        print_info("Available snapshots with tag 'immich':")
        print()
        result = subprocess.run(
            ["restic", "-r", self.repo, "snapshots", "--tag", "immich"],
            capture_output=False
        )
        print()
        return result.returncode == 0

    def restore(self, snapshot_id: str, target_dir: Path) -> bool:
        """Restore a snapshot to the target directory."""
        print_info(f"Creating restore directory structure...")
        target_dir.mkdir(parents=True, exist_ok=True)

        print_info(f"Restoring snapshot {snapshot_id} to {target_dir}...")
        result = subprocess.run(
            ["restic", "-r", self.repo, "restore", snapshot_id,
             "--target", str(target_dir), "--tag", "immich"]
        )
        if result.returncode != 0:
            print_error("Failed to restore snapshot")
            return False

        print_success("Snapshot restored successfully")
        return True


class DockerOperations:
    """Handles Docker operations for the DR test."""

    COMPOSE_FILE = "docker-compose-dr.yml"

    def __init__(self, restore_dir: Path):
        self.restore_dir = restore_dir
        self.compose_path = restore_dir / self.COMPOSE_FILE

    def generate_env_file(self, photo_path: Path) -> None:
        """Generate the .env file for Docker Compose."""
        print_info("Generating .env file...")

        env_content = f"""# Immich DR Test Environment
UPLOAD_LOCATION={photo_path}
DB_DATA_LOCATION={self.restore_dir}/postgres
REDIS_DATA_LOCATION={self.restore_dir}/redis

# Database
DB_HOSTNAME=immich-db
DB_USERNAME=immich
DB_PASSWORD=immich
DB_DATABASE_NAME=immich

# Redis
REDIS_HOSTNAME=immich-redis

# Immich
IMMICH_VERSION=release
IMMICH_MACHINE_LEARNING_ENABLED=false
"""
        (self.restore_dir / ".env").write_text(env_content)
        print_success(".env file generated")

    def generate_compose_file(self) -> None:
        """Generate the docker-compose-dr.yml file."""
        print_info("Generating docker-compose-dr.yml...")

        (self.restore_dir / "postgres").mkdir(parents=True, exist_ok=True)
        (self.restore_dir / "redis").mkdir(parents=True, exist_ok=True)

        compose_content = '''version: "3.8"

services:
  immich-server:
    container_name: immich-server-dr
    image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}
    command: ["start.sh", "immich"]
    volumes:
      - ${UPLOAD_LOCATION}:/usr/src/app/upload
    env_file:
      - .env
    ports:
      - 2283:3001
    depends_on:
      immich-db:
        condition: service_healthy
      immich-redis:
        condition: service_started
    restart: unless-stopped

  immich-db:
    container_name: immich-db-dr
    image: tensorchord/pgvecto-rs:pg16-v0.2.0
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_DB: ${DB_DATABASE_NAME}
    volumes:
      - ${DB_DATA_LOCATION}:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USERNAME} -d ${DB_DATABASE_NAME}"]
      interval: 5s
      timeout: 5s
      retries: 10
    restart: unless-stopped

  immich-redis:
    container_name: immich-redis-dr
    image: redis:7-alpine
    volumes:
      - ${REDIS_DATA_LOCATION}:/data
    restart: unless-stopped
'''
        self.compose_path.write_text(compose_content)
        print_success("docker-compose-dr.yml generated")

    def start_containers(self) -> bool:
        """Start the Docker containers."""
        print_info("Starting containers...")
        result = subprocess.run(
            ["docker", "compose", "-f", str(self.compose_path), "up", "-d"],
            cwd=self.restore_dir
        )
        if result.returncode != 0:
            return False
        print_success("Containers started")
        return True

    def stop_containers(self) -> bool:
        """Stop and remove the Docker containers."""
        if not self.compose_path.exists():
            return False

        result = subprocess.run(
            ["docker", "compose", "-f", str(self.compose_path), "down", "-v"],
            cwd=self.restore_dir
        )
        return result.returncode == 0

    def show_status(self) -> bool:
        """Show container status."""
        if not self.compose_path.exists():
            print_error(f"No DR test environment found at {self.restore_dir}")
            return False

        subprocess.run(
            ["docker", "compose", "-f", str(self.compose_path), "ps"],
            cwd=self.restore_dir
        )
        return True

    def show_logs(self) -> bool:
        """Follow container logs."""
        if not self.compose_path.exists():
            print_error(f"No DR test environment found at {self.restore_dir}")
            return False

        subprocess.run(
            ["docker", "compose", "-f", str(self.compose_path), "logs", "-f"],
            cwd=self.restore_dir
        )
        return True


class DatabaseRestore:
    """Handles database restoration with format detection."""

    def __init__(self, sql_dump: Path):
        self.sql_dump = sql_dump
        self.format = FormatDetector.detect(sql_dump)

    def restore(self) -> bool:
        """Restore the database using the appropriate method."""
        print_info(f"Detected dump format: {self.format.value}")
        print_info("Waiting for database to be ready...")
        time.sleep(10)

        if self.format == DumpFormat.PLAIN_SQL:
            return self._restore_plain()
        elif self.format == DumpFormat.CUSTOM:
            return self._restore_custom()
        elif self.format == DumpFormat.DIRECTORY:
            return self._restore_directory()
        return False

    def _restore_plain(self) -> bool:
        """Restore from plain SQL format."""
        print_info("Restoring from plain SQL format...")
        with open(self.sql_dump, "r") as f:
            result = subprocess.run(
                ["docker", "exec", "-i", "immich-db-dr",
                 "psql", "-U", "immich", "-d", "immich"],
                stdin=f
            )
        return self._handle_result(result.returncode)

    def _restore_custom(self) -> bool:
        """Restore from PostgreSQL custom format."""
        print_info("Restoring from PostgreSQL custom format...")
        with open(self.sql_dump, "rb") as f:
            result = subprocess.run(
                ["docker", "exec", "-i", "immich-db-dr",
                 "pg_restore", "-U", "immich", "-d", "immich",
                 "--clean", "--if-exists", "--no-owner", "--no-privileges"],
                stdin=f
            )
        return self._handle_result(result.returncode)

    def _restore_directory(self) -> bool:
        """Restore from directory format."""
        print_info("Restoring from directory format...")

        # Copy directory to container
        result = subprocess.run(
            ["docker", "cp", str(self.sql_dump), "immich-db-dr:/tmp/dump_dir"]
        )
        if result.returncode != 0:
            print_error("Failed to copy dump directory to container")
            return False

        result = subprocess.run(
            ["docker", "exec", "immich-db-dr",
             "pg_restore", "-U", "immich", "-d", "immich",
             "--clean", "--if-exists", "--no-owner", "--no-privileges",
             "/tmp/dump_dir"]
        )
        return self._handle_result(result.returncode)

    def _handle_result(self, returncode: int) -> bool:
        """Handle the restore result."""
        if returncode != 0:
            print_error("Failed to restore database")
            print_info("Manual restore commands:")
            print(f"  Plain SQL:     docker exec -i immich-db-dr psql -U immich -d immich < {self.sql_dump}")
            print(f"  Custom format: docker exec -i immich-db-dr pg_restore -U immich -d immich "
                  f"--clean --if-exists --no-owner --no-privileges < {self.sql_dump}")
            return False

        print_success("Database restored successfully")
        return True


def check_dependencies() -> bool:
    """Check that required dependencies are installed."""
    missing = []
    for cmd in ["restic", "docker"]:
        result = subprocess.run(
            ["which", cmd], capture_output=True
        )
        if result.returncode != 0:
            missing.append(cmd)

    if missing:
        print_error(f"Missing required dependencies: {', '.join(missing)}")
        print("Please install the missing dependencies and try again.")
        return False
    return True


def detect_paths(config: DrConfig) -> bool:
    """Detect restored data paths."""
    print_info("Detecting restored data paths...")

    # Look for photo library
    photo_candidates = [
        config.restore_dir / "library",
        config.restore_dir / "data" / "library",
        config.restore_dir / "upload",
    ]
    for path in photo_candidates:
        if path.is_dir():
            config.photo_path = path
            break

    if config.photo_path is None:
        print_error("Could not find photo library in restored data")
        print_info("Searched locations:")
        for path in photo_candidates:
            print(f"  - {path}")
        return False

    # Look for SQL dump - prioritize .dump files (custom format) over .sql
    dump_candidates = [
        config.restore_dir / "database.dump",
        config.restore_dir / "db" / "database.dump",
        config.restore_dir / "immich.dump",
        config.restore_dir / "database.pgdump",
        config.restore_dir / "database.sql",
        config.restore_dir / "db" / "database.sql",
        config.restore_dir / "immich.sql",
    ]
    for path in dump_candidates:
        if path.exists():
            config.sql_dump = path
            break

    if config.sql_dump is None:
        print_error("Could not find SQL dump in restored data")
        print_info("Searched locations:")
        for path in dump_candidates:
            print(f"  - {path}")
        return False

    print_success(f"Photo library found: {config.photo_path}")
    print_success(f"SQL dump found: {config.sql_dump}")
    return True


def wait_for_immich(max_attempts: int = 60) -> bool:
    """Wait for Immich to become ready."""
    print_info("Waiting for Immich to be ready...")

    import urllib.request
    import urllib.error

    for attempt in range(max_attempts):
        try:
            req = urllib.request.urlopen(
                "http://localhost:2283/api/server-info/ping",
                timeout=2
            )
            if req.status == 200:
                print()
                print_success("Immich is ready!")
                return True
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError):
            pass

        print(".", end="", flush=True)
        time.sleep(2)

    print()
    print_error("Immich did not become ready in time")
    print_info("Check logs with: python immich-dr-test.py logs")
    return False


def prompt_continue(config: DrConfig) -> bool:
    """Prompt user to continue with restore."""
    print_warning(f"About to restore snapshot: {config.snapshot_id}")
    print_warning(f"Restore directory: {config.restore_dir}")
    print()

    try:
        response = input("Continue? (y/N): ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return False

    return response in ("y", "yes")


def show_success_message(script_name: str) -> None:
    """Show the success message with useful commands."""
    print()
    print_success("==========================================")
    print_success("  Immich DR Test Environment Ready!")
    print_success("==========================================")
    print()
    print_info(f"Access Immich at: {Colors.GREEN}http://localhost:2283{Colors.NC}")
    print()
    print_info("Useful commands:")
    print(f"  {script_name} status    - Show container status")
    print(f"  {script_name} logs      - Follow container logs")
    print(f"  {script_name} cleanup   - Stop and remove test environment")
    print()
    print_warning("Note: Machine learning features are disabled in DR test mode")
    print()


def cleanup(config: DrConfig) -> None:
    """Clean up the DR test environment."""
    print_warning("Stopping containers and removing test data...")

    docker_ops = DockerOperations(config.restore_dir)
    if docker_ops.compose_path.exists():
        docker_ops.stop_containers()
        print_success("Containers stopped")

    if config.restore_dir.exists():
        print_info(f"Removing restore directory: {config.restore_dir}")
        import shutil
        shutil.rmtree(config.restore_dir)
        print_success("Test data removed")

    print_success("Cleanup complete")


def run_full_restore(config: DrConfig) -> bool:
    """Run the full restore workflow."""
    if not check_dependencies():
        return False

    restic_ops = ResticOperations(config.restic_repo)
    restic_ops.check_password()

    if not restic_ops.list_snapshots():
        print_error("Failed to list snapshots. Check repository path and password.")
        return False

    if not prompt_continue(config):
        print_info("Restore cancelled.")
        return True

    if not restic_ops.restore(config.snapshot_id, config.restore_dir):
        return False

    if not detect_paths(config):
        return False

    docker_ops = DockerOperations(config.restore_dir)
    docker_ops.generate_env_file(config.photo_path)
    docker_ops.generate_compose_file()

    if not docker_ops.start_containers():
        print_error("Failed to start containers")
        return False

    db_restore = DatabaseRestore(config.sql_dump)
    if not db_restore.restore():
        return False

    if not wait_for_immich():
        return False

    show_success_message(sys.argv[0])
    return True


def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Immich Disaster Recovery Test Script",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                    Restore latest snapshot
  %(prog)s abc123ef           Restore specific snapshot
  %(prog)s cleanup            Stop and remove test environment
  %(prog)s status             Show container status
  %(prog)s logs               Follow container logs

Environment Variables:
  RESTIC_REPO       Restic repository path (default: /mnt/e/backups/immich)
  RESTIC_PASSWORD   Restic repository password (will prompt if not set)
  RESTORE_DIR       Directory to restore to (default: $HOME/dr-test/immich)
"""
    )
    parser.add_argument(
        "command",
        nargs="?",
        default="latest",
        help="Command (cleanup, status, logs) or snapshot ID (default: latest)"
    )

    args = parser.parse_args()

    # Configuration from environment
    config = DrConfig(
        restic_repo=os.environ.get("RESTIC_REPO", "/mnt/e/backups/immich"),
        restore_dir=Path(os.environ.get("RESTORE_DIR", Path.home() / "dr-test" / "immich")),
        snapshot_id=args.command if args.command not in ("cleanup", "status", "logs") else "latest"
    )

    docker_ops = DockerOperations(config.restore_dir)

    # Handle commands
    if args.command == "cleanup":
        cleanup(config)
        return 0
    elif args.command == "status":
        return 0 if docker_ops.show_status() else 1
    elif args.command == "logs":
        return 0 if docker_ops.show_logs() else 1

    # Run full restore
    print_info("Immich Disaster Recovery Test Script")
    print()

    return 0 if run_full_restore(config) else 1


if __name__ == "__main__":
    sys.exit(main())
