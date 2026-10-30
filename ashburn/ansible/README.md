# Ashburn Ansible

Ansible is used **after Terraform** provisions the ESXi bare-metal server and temporary Ubuntu installer in PhoenixNAP.

| Stage | Command | What it does |
| --- | --- | --- |
| Setup | `bash ashburn/scripts/setup-ansible.sh` | Prepare Mac Ansible and VMware collection |
| Prepare | `bash ashburn/scripts/vcsa.sh prepare` | Verify/stage VCSA ISO, mount it, prepare ESXi port group and JSON |
| Precheck | `bash ashburn/scripts/vcsa.sh precheck` | Run VMware VCSA CLI checks |
| Deploy | `bash ashburn/scripts/vcsa.sh deploy` | Install the vCenter appliance VM inside ESXi; approval required |
| Register | `bash ashburn/scripts/register-esxi.sh` | Create Datacenter and add the ESXi host to vCenter |

The **VCSA** playbook executes on the Mac and uses SSH/SCP for Ubuntu 20.04, avoiding Ansible Core 2.21's lack of Python 3.8 managed-host support. Host registration runs on the Mac using the `vmware.vmware` collection and the same Python virtual environment.

See [installation prerequisites, SHA verification, approvals and troubleshooting](../../docs/vcsa-ansible.md). The [top-level README](../../README.md) has the shortest create/install/destroy commands.

**Safety:** `register-esxi.sh` runs idempotently, registers a standalone host in `/Datacenter/host`, and does not format disks, deploy VMs or modify Terraform resources. VCSA deployment itself requires explicit approval and confirmation.
