#!/usr/bin/env bash
# One-time Mac setup. Keep Ansible and VMware dependencies in a private venv.
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
if ! command -v python3.14 >/dev/null 2>&1; then
  command -v brew >/dev/null || { echo "Install Homebrew Python 3.14 first." >&2; exit 1; }
  brew install python@3.14
fi
if [[ ! -x ashburn/.venv/bin/python ]]; then
  python3.14 -m venv ashburn/.venv
fi
ashburn/.venv/bin/python -m pip install --upgrade pip
ashburn/.venv/bin/python -m pip install 'ansible-core>=2.21,<2.22' requests pyvmomi
ashburn/.venv/bin/ansible-galaxy collection install -r ashburn/ansible/requirements.yml
echo "Ansible ready. Run: bash ashburn/scripts/vcsa.sh prepare"
