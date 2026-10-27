# Replace the Seattle ESXi /30 with a /29

This is a **two-stage, operator-approved** migration for Wayne's existing host:

- Old server ID: `6ae0430e5f894da540fb7126`
- Old management IP: `131.153.165.146`
- Replacement: `s2.c2.large` in `SEA`, `esxi/esxi80`, one purchased public **IPv4 /29**
- Hourly cap: **US$0.50** for one server plus one /29 allocation

Published rates suggest US$0.40 server + 8 x US$0.0035 IPv4 = **US$0.428/hour**.
Terraform fetches account-specific Seattle prices from phoenixNAP's Billing API
via `data.pnap_products` and **refuses to provision** if the unit quote is
missing, ambiguous or above the budget. This is a pre-apply control, **not a
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
Make sure `terraform.tfvars` contains:

```hcl
approve_hourly_costs = true
confirm_esxi_image = true
```

Keep `confirm_previous_server_retired` at its default `false` until the
old server and `/30` have been removed.

## 2. Obtain the live /29 quote before destroying the old host

```bash
bash scripts/rebuild_29.sh quote
```

The command now runs an **independent, pricing-only Terraform configuration**
under quote/. It has no managed resources and reads only the server pricing
and the full PUBLIC_IP billing SKU catalog, including plans whose location is
GLOBAL. This cannot change, destroy, or purchase anything and does not need
approve_hourly_costs=true.

**Diagnostic step:** Examine/paste the public_ip_catalog output before
continuing. The full catalog exposes the price unit, pricing model, location,
and SKU so we can confirm which price applies to a Seattle IPv4 /29.
The current provisioning guard deliberately still refuses to purchase when
that mapping is ambiguous. A published price is not account-specific proof.

**Do not run retire or create until the main /29 cost calculation matches
the confirmed live catalog and a new guarded plan succeeds.**

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

1. Fetches the live `s2.c2.large` hourly quote and hourly `PUBLIC_IP` unit
   rates for Seattle, selecting a single unambiguous rate (or an explicitly
   supplied SKU in `public_ipv4_sku`).
2. Calculates **server + eight IPv4 addresses**; blocks the operation if the
   live price is unavailable, zero, ambiguous or above **US$0.50/hour**.
3. Previews and machine-checks the exact Terraform plan: **one `/29` block
   and one ESXi host to create; no other changes**.
4. Requires you to type `BUY SEA /29` before applying the approved plan.

The server is provisioned with `USER_DEFINED` IP block configuration pointing
to the new separately managed `pnap_ip_block`. `delete_ip_blocks = false` on
the new server avoids cascading deletion of this Terraform-managed block;
normal future `terraform destroy` will remove the server first, then the block.

If phoenixNAP returns more than one different hourly public IP unit price,
the plan fails closed. Inspect the Billing API's Seattle PUBLIC_IP SKUs,
identify the IPv4 SKU, and set `public_ipv4_sku` in `terraform.tfvars`.
Do not guess the SKU or disable the cost guard.

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
