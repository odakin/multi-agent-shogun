#!/usr/bin/env python3
"""
Migrate shogun_to_karo.yaml to per-cmd files.

Reads all commands from queue/shogun_to_karo.yaml and writes each one
to queue/cmds/cmd_XXX.yaml. Then replaces the original file with an empty list.

Idempotent: skips commands that already exist as per-cmd files.
"""

import sys
import yaml
from pathlib import Path


def main():
    repo_root = Path(__file__).resolve().parent.parent
    queue_dir = repo_root / 'queue'
    cmds_dir = queue_dir / 'cmds'
    shogun_file = queue_dir / 'shogun_to_karo.yaml'

    cmds_dir.mkdir(parents=True, exist_ok=True)

    if not shogun_file.exists():
        print("shogun_to_karo.yaml not found, nothing to migrate.", file=sys.stderr)
        return

    with open(shogun_file, 'r', encoding='utf-8') as f:
        data = yaml.safe_load(f)

    if not data:
        print("shogun_to_karo.yaml is empty, nothing to migrate.", file=sys.stderr)
        return

    # Support flat list format (primary) and dict format
    if isinstance(data, list):
        queue = data
    else:
        key = 'commands' if 'commands' in data else 'queue'
        queue = data.get(key, [])

    if not isinstance(queue, list) or not queue:
        print("No commands found to migrate.", file=sys.stderr)
        return

    migrated = 0
    skipped = 0

    for cmd in queue:
        cmd_id = cmd.get('id', 'unknown')
        target_file = cmds_dir / f'{cmd_id}.yaml'

        if target_file.exists():
            print(f"  SKIP {cmd_id} (already exists)", file=sys.stderr)
            skipped += 1
            continue

        with open(target_file, 'w', encoding='utf-8') as f:
            yaml.dump(cmd, f, allow_unicode=True, sort_keys=False, default_flow_style=False)
        print(f"  MIGRATED {cmd_id} -> {target_file.name}", file=sys.stderr)
        migrated += 1

    # Clear the original file
    with open(shogun_file, 'w', encoding='utf-8') as f:
        f.write('[]\n')

    print(f"\nDone: {migrated} migrated, {skipped} skipped. "
          f"shogun_to_karo.yaml cleared.", file=sys.stderr)


if __name__ == '__main__':
    main()
