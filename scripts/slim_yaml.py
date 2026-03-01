#!/usr/bin/env python3
"""
YAML Slimming Utility

Removes completed/archived items from YAML queue files to maintain performance.
- For Karo: Archives done/cancelled commands from shogun_to_karo.yaml
- For all agents: Archives read: true messages from inbox files
"""

import sys
import yaml
from pathlib import Path
from datetime import datetime


def load_yaml(filepath):
    """Safely load YAML file."""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return yaml.safe_load(f) or {}
    except FileNotFoundError:
        return {}
    except yaml.YAMLError as e:
        print(f"Error parsing {filepath}: {e}", file=sys.stderr)
        return {}


def save_yaml(filepath, data):
    """Safely save YAML file."""
    try:
        with open(filepath, 'w', encoding='utf-8') as f:
            yaml.dump(data, f, allow_unicode=True, sort_keys=False, default_flow_style=False)
        return True
    except Exception as e:
        print(f"Error writing {filepath}: {e}", file=sys.stderr)
        return False


def get_timestamp():
    """Generate archive filename timestamp."""
    return datetime.now().strftime('%Y%m%d%H%M%S')


def slim_shogun_to_karo():
    """Archive done/cancelled commands from shogun_to_karo.yaml."""
    queue_dir = Path(__file__).resolve().parent.parent / 'queue'
    archive_dir = queue_dir / 'archive'
    shogun_file = queue_dir / 'shogun_to_karo.yaml'

    if not shogun_file.exists():
        print(f"Warning: {shogun_file} not found", file=sys.stderr)
        return True

    data = load_yaml(shogun_file)
    if not data:
        return True

    # Support flat list format (primary) and dict format with 'commands'/'queue' keys
    ARCHIVE_STATUSES = {'done', 'done_ng', 'stalled', 'cancelled', 'qc_pass'}
    is_flat_list = isinstance(data, list)
    if is_flat_list:
        queue = data
    else:
        key = 'commands' if 'commands' in data else 'queue'
        if key not in data:
            return True
        queue = data[key]

    if not isinstance(queue, list):
        print("Error: queue is not a list", file=sys.stderr)
        return False

    # Separate active and archived commands
    active = []
    archived = []

    for cmd in queue:
        status = cmd.get('status', 'unknown')
        if status in ARCHIVE_STATUSES:
            archived.append(cmd)
        else:
            active.append(cmd)

    # If nothing to archive, return success without writing
    if not archived:
        return True

    # Write archived commands to timestamped file
    archive_timestamp = get_timestamp()
    archive_file = archive_dir / f'shogun_to_karo_{archive_timestamp}.yaml'

    archive_data = archived if is_flat_list else {key: archived}
    if not save_yaml(archive_file, archive_data):
        return False

    # Update main file with active commands only
    if is_flat_list:
        if not save_yaml(shogun_file, active):
            print(f"Error: Failed to update {shogun_file}, but archive was created", file=sys.stderr)
            return False
    else:
        data[key] = active
        if not save_yaml(shogun_file, data):
            print(f"Error: Failed to update {shogun_file}, but archive was created", file=sys.stderr)
            return False

    print(f"Archived {len(archived)} commands to {archive_file.name}", file=sys.stderr)
    return True


def slim_inbox(agent_id):
    """Archive read: true messages from inbox file."""
    queue_dir = Path(__file__).resolve().parent.parent / 'queue'
    archive_dir = queue_dir / 'archive'
    inbox_file = queue_dir / 'inbox' / f'{agent_id}.yaml'

    if not inbox_file.exists():
        # Inbox doesn't exist yet - that's fine
        return True

    data = load_yaml(inbox_file)
    if not data or 'messages' not in data:
        return True

    messages = data.get('messages', [])
    if not isinstance(messages, list):
        print("Error: messages is not a list", file=sys.stderr)
        return False

    # Separate unread and archived messages
    unread = []
    archived = []

    for msg in messages:
        is_read = msg.get('read', False)
        if is_read:
            archived.append(msg)
        else:
            unread.append(msg)

    # If nothing to archive, return success without writing
    if not archived:
        return True

    # Write archived messages to timestamped file
    archive_timestamp = get_timestamp()
    archive_file = archive_dir / f'inbox_{agent_id}_{archive_timestamp}.yaml'

    archive_data = {'messages': archived}
    if not save_yaml(archive_file, archive_data):
        return False

    # Update main file with unread messages only
    data['messages'] = unread
    if not save_yaml(inbox_file, data):
        print(f"Error: Failed to update {inbox_file}, but archive was created", file=sys.stderr)
        return False

    if archived:
        print(f"Archived {len(archived)} messages from {agent_id} to {archive_file.name}", file=sys.stderr)
    return True


def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        print("Usage: slim_yaml.py <agent_id>", file=sys.stderr)
        sys.exit(1)

    agent_id = sys.argv[1]

    # Ensure archive directory exists
    archive_dir = Path(__file__).resolve().parent.parent / 'queue' / 'archive'
    archive_dir.mkdir(parents=True, exist_ok=True)

    # Process shogun_to_karo if this is Karo
    if agent_id == 'karo':
        if not slim_shogun_to_karo():
            sys.exit(1)

    # Process inbox for all agents
    if not slim_inbox(agent_id):
        sys.exit(1)

    sys.exit(0)


if __name__ == '__main__':
    main()
