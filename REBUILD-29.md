# Replace the Seattle ESXi /30 with a /29

This is a **two-stage, operator-approved** migration for Wayne's existing host:

- Old server ID: `6ae0430e5f894da540fb7126`
- Old management IP: `131.153.165.146`
- Replacement: `s2.c2.large` in `SEA`, `esxi/esxi80`, one purchased public **IPv4 /29**
- Hourly cap: **US$0.50** for one server plus one /29 allocation

Wayne's live catalog identifies **GLOBAL /29 range SKU `W0I2-DIVY-ZJVP`**
(`product_code=range-29`) at **US$0.028/hour for the whole range**.
With the confirmed Seattle server rate US$0.40/hour, the expected combined
rate is **US$0.428/hour**. Do **not** multiply the /29 range charge by eight.
Terraform rechecks these account-specific prices through `data.pnap_products`
and refuses to provision if the exact SKU/rate is missing, ambiguous, or above
the budget. This is a pre-apply control, **not a
live billing limit**; taxes, bandwidth overages, licensing and other resources
are outside that calculation.

**WARNING:** The old ESXi disks, VMs and data are lost when the old host is
destroyed. Make any needed backups first. Its `/30` will be released, and the
replacement management IP will change.

## 1. Get the branch and check the quote automation

From the Mac in `/Users/wdovey/OCP/phoenixnap-vsphere-terraform`:

```bash
git fetch origin
# Checkout the reviewed /29 feature branch or merge its PR first.
terraform init
terraform validate
python3 -m unittest discover -s tests -v
```

Use your existing `~/.pnap/config.yaml` or configured provider credentials.
Confirm the supplied ESXi image is 8.0U2 as requested, then set
`confirm_esxi_image = true` in your ignored `terraform.tfvars`.
The guarded script passes cost approval **only within its disposable
verification and purchase plans**, and requires separate typed authorization
before destruction and purchase. Keep `confirm_previous_server_retired`
at its default `false` until the original host is gone.

## 2. Verify the approved /29 quote before destroying the old host

```bash
bash scripts/rebuild_29.sh verify
```

This mode builds a **temporary plan only**, re-reads the live account pricing,
and machine-checks the exact GLOBAL hourly /29 SKU and the calculation
`0.40 + 0.028 = 0.428 USD/hour`. It also enforces the US$0.50/hour budget,
then removes the temporary plan **without applying it**. The preview may
include modifications to the currently running server; those are **not**
applied by `verify`.

For raw catalog inspection only, `bash scripts/rebuild_29.sh quote` uses
the separate `quote/` Terraform configuration with data sources only.

**Do not run retire unless verify passes, your existing ESXi workloads are
backed up, and you are ready to lose the current server and IP address.**

## 3. Retire the original /30-backed host

```bash
bash scripts/rebuild_29.sh retire
```

The script **rechecks the live /29 quote before deleting anything**. It then
checks the current Terraform state ID, creates a **destroy-only
plan** for `pnap_server.esxi[0]`, confirms no other resource will change,
displays the plan, and requires you to type the exact server ID to approve.
It applies only after that confirmation. Verify the plan shows the old
`delete_ip_blocks = true` setting before confirming.

After completion, **check the phoenixNAP BMC portal** that both the old
server and its old `/30` allocation are deleted; IP allocations can incur
charges even when detached.

## 4. Purchase /29 and create replacement ESXi

```bash
bash scripts/rebuild_29.sh create
```

This phase refuses to run while the old server is still in Terraform state,
and asks you to confirm old IP allocation cleanup. It then:

1. Fetches the live `s2.c2.large` Seattle hourly rate and approved
   GLOBAL `range-29` public IPv4 hourly rate for SKU `W0I2-DIVY-ZJVP`.
2. Calculates **server + one complete /29 range**; blocks if the exact
   SKU/rate is unavailable, ambiguous or over **US$0.50/hour**.
3. Previews and machine-checks the exact Terraform plan: **one `/29` block
   and one ESXi host to create; no other changes**.
4. Requires you to type `BUY SEA /29` before applying the approved plan.

The server is provisioned with `USER_DEFINED` IP block configuration pointing
to the new separately managed `pnap_ip_block`. `delete_ip_blocks = false` on
the new server avoids cascading deletion of this Terraform-managed block;
normal future `terraform destroy` will remove the server first, then the block.

The account-approved `GLOBAL` /29 SKU is pinned in `public_ipv4_sku`.
If it disappears or phoenixNAP changes its rate, the live quote is
recalculated and the plan fails closed if ambiguous or above the cap.
Changing the approved SKU requires reviewing and editing Terraform source;
do not remove the cost guard.

## 5. Configure vCenter only after ESXi is online

```bash
terraform output esxi_public_ip
terraform output esxi_management_url
terraform output seattle_public_ipv4_cidr
```

The `/29` has eight addresses, **five assignable**. ESXi consumes one;
choose a separate unused assignable public IP for vCenter and obtain the
correct prefix, gateway, VLAN/port group and DNS configuration from phoenixNAP.
Then follow the repository's guarded `scripts/vcsa.py` workflow using your
locally mounted installer media. vCenter deployment is not part of this step.

> Credentials, cached Terraform state and binary `.tfplan` files must stay
> private. `terraform apply` can trigger charges even when the host deployment
> later fails; separately purchased IP blocks can keep billing until deleted.
