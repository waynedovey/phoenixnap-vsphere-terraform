# Register the Ashburn ESXi host in vCenter

This small Ansible workflow automates only the vCenter inventory tasks:

1. Discover the current ESXi management IP and root password from the **Ashburn** Terraform state.
2. Read the vCenter IP from the ignored `private/vcsa-config-ashburn.json`.
3. Check that the target is a vCenter API.
4. Create `Datacenter` if missing.
5. Idempotently register the standalone ESXi host under `Datacenter/host`.
6. List the resulting host inventory.

It does **not** format disks, create datastores, deploy or destroy cloud resources,
or alter the old Seattle state. The `vmware.vmware.esxi_host` Ansible module
uses `state: present` and does not forcefully take ownership from another
vCenter.

## Requirements

On the Mac, with Terraform state already initialized in `ashburn/`:

- `terraform`, `jq`, `govc`, `ansible-playbook`
- `vmware.vmware` collection 2.11.0
- Its Python dependencies in the Python interpreter used by Ansible
  (typically `pyvmomi` and `requests`).
- Existing private file `private/vcsa-config-ashburn.json` with the **Ashburn**
  ESXi and VCSA addresses.

Install the Ansible collection once:

```bash
ansible-galaxy collection install -r ashburn/ansible/requirements.yml
```

Install Python dependencies into the environment providing `ansible-playbook`;
use a Python virtual environment if the system Python is externally managed.

## Register

From the repository root:

```bash
bash ashburn/scripts/register-esxi.sh
```

The wrapper prompts privately for the VCSA SSO password. It reads the ESXi
root password from Terraform state without printing it. The script is Bash so
the password prompt works even when your interactive Mac shell is Zsh.

To supply the SSO password through an existing secret manager or an environment
variable, set `VCSA_SSO_PASSWORD` before running. Never put the password on
the command line, in Terraform variables, Git, or shell history.

## Verify

```bash
export GOVC_URL=https://192.240.198.139/sdk
export GOVC_USERNAME=administrator@vsphere.local
export GOVC_INSECURE=1
export GOVC_DATACENTER=Datacenter
# Set GOVC_PASSWORD privately to your vCenter SSO password
govc host.info
govc find / -type h
```

The playbook uses `validate_certs: false` and `GOVC_INSECURE=1` because
this temporary lab currently has self-signed or non-compliant certificates.
For long-lived environments, establish trusted CA certificates or validate
and pin the ESXi certificate fingerprint out of band. Without an explicit
fingerprint, `vmware.vmware.esxi_host` fetches and trusts the fingerprint
presented by the host.

It registers the ESXi host directly in the Datacenter's root host folder,
not in a cluster. Storage is deliberately not automated: the current ESXi
inventory shows only one Micron NVMe boot disk with `datastore1` and
`OSDATA` partitions. Reformatting it would destroy ESXi and VM data.

If registration fails, review the vCenter Tasks and Events. Avoid
`force_add: true` unless you explicitly intend to transfer a host already
managed by a different vCenter.
