# WordPress on AWS: EC2 → RDS, with Bash + AWS CLI

A small, readable template for getting a WordPress site running on AWS with your own domain.
It uses only **Bash + AWS CLI v2**: no Terraform, no CDK. Every AWS call is visible in the scripts and
commented with *why* it is done, which makes it useful for learning and for explaining the architecture.

- `01-deploy-wordpress.sh`: a single EC2 server with Apache, PHP, MariaDB and WordPress, plus an Elastic IP and
  Route 53 DNS. Optional `--https` adds Let's Encrypt.
- `02-attach-rds.sh`: moves the database to a private **Amazon RDS for MySQL** instance, on top of the
  existing server, with automatic rollback if anything fails.
- `99-teardown.sh`: deletes everything again (asks for confirmation).

## Architecture (end state after both scripts)

```
                 Internet
                    |
   Route 53: example.com / www.example.com   (A records -> Elastic IP, TTL 60)
                    |
   [ SG: web-sg ]  80, 443 from 0.0.0.0/0 ; 22 from YOUR IP only
   EC2 t3.micro (Amazon Linux 2023) - Apache + PHP-FPM + WordPress
     IAM role: AmazonSSMManagedInstanceCore + read /<PROJECT>/*   (no SSH needed for automation)
                    |  3306 (TLS)
   [ SG: db-sg ]   3306 only from web-sg (security-group reference, not a CIDR)
   RDS MySQL 8.4 db.t3.micro (private, PubliclyAccessible=false, 20 GB gp3, single-AZ,
                              DB subnet group = default VPC subnets)

   Secrets: SSM Parameter Store SecureString  /<PROJECT>/wp/admin-password, /<PROJECT>/db/*
```

Everything goes in the **default VPC** of your region, and every resource is tagged `Project=<PROJECT>`.
Sizes are Free-Tier friendly: t3.micro, db.t3.micro, 20 GB, no Multi-AZ.

## Prerequisites

1. **AWS CLI v2** (`brew install awscli`) and, optionally, **shellcheck** for linting.
2. **Credentials**: `aws login` (or `aws configure`), then check with `aws sts get-caller-identity`.
   Use an IAM user/role with administrator rights rather than the account root user.
3. **A domain with a public Route 53 hosted zone.** The domain's registrar must use that zone's four name
   servers. If the domain is registered through Route 53, make sure the registrant email is **verified**.
   Otherwise the registry suspends the domain (`clientHold`) and it disappears from DNS.
4. The **default VPC** must exist in your region (`aws ec2 create-default-vpc` recreates it).
5. `curl`, `openssl`, `dig` (preinstalled on macOS and most Linux). Works with macOS's built-in bash 3.2.

## Quick start

```bash
cp config.example.env config.env      # then edit: DOMAIN, WP_ADMIN_EMAIL, PROJECT, ...
chmod +x 01-deploy-wordpress.sh 02-attach-rds.sh 99-teardown.sh

./01-deploy-wordpress.sh              # ~6-8 min   (add --https once your DNS resolves publicly)
./02-attach-rds.sh                    # ~10-15 min (mostly RDS creating the database)
./99-teardown.sh                      # when finished: deletes everything, stops all charges
```

All three scripts are **idempotent**. Running one again finds the existing resources (by name or `Project` tag)
and reuses them instead of creating duplicates.

**WordPress admin password** (user from `WP_ADMIN_USER`):

```bash
aws ssm get-parameter --name /<PROJECT>/wp/admin-password --with-decryption --query Parameter.Value --output text
```

**Shell on the server:** `aws ssm start-session --target <instance-id>` (needs the
[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)),
or `ssh -i <PROJECT>-key.pem ec2-user@<elastic-ip>` (only from the IP the script detected).

## Files

| File | What it is |
|---|---|
| `config.example.env` | Template for **your** settings. Copy to `config.env` (git-ignored). |
| `lib/common.sh` | Loads `config.env`, derives resource names, and provides helpers: logging, state file, idempotent SG rules, secrets, SSM Run Command, HTTP/DNS checks. |
| `01-deploy-wordpress.sh` | Key pair, web-sg, IAM role, EC2 + WordPress, Elastic IP, DNS, health checks, optional HTTPS. |
| `02-attach-rds.sh` | db-sg, DB subnet group, secrets, RDS MySQL, migration via SSM Run Command, verification. |
| `99-teardown.sh` | Deletes everything in dependency order. |
| `remote/wordpress-user-data.sh` | EC2 user-data: installs Apache, PHP, MariaDB and WordPress on first boot. |
| `remote/migrate-to-rds.sh` | Runs on the instance via SSM: dump → import into RDS → switch wp-config → stop MariaDB. Auto-rollback. |
| `remote/rollback-to-local-db.sh` | Restores the pre-RDS `wp-config.php` and restarts MariaDB. |
| `remote/enable-https.sh` | certbot + Apache TLS + renewal timer (for `--https`). |
| `state.env`, `<PROJECT>-key.pem` | Created at run time (git-ignored). |

## What each script does

### 01-deploy-wordpress.sh
1. **Pre-flight**: credentials, default VPC, hosted zone. Stops before creating anything if one is missing.
2. **Key pair** (ed25519): `.pem` saved locally with `chmod 400`.
3. **web-sg**: 80/443 open to the world; 22 only from your current IP (via `checkip.amazonaws.com`).
   If your IP changed since the last run, the old SSH rule is removed.
4. **IAM role + instance profile**: `AmazonSSMManagedInstanceCore` + read access to `/<PROJECT>/*` parameters only.
5. **Admin password**: random value stored as an SSM SecureString. It is never printed and never in user-data.
6. **EC2**: latest Amazon Linux 2023 AMI (from AWS's public SSM parameter), in an AZ that offers the instance type,
   with IMDSv2 required, an encrypted gp3 root volume, and `CpuCredits=standard` (no surprise burst charges). User-data:
   adds swap, installs Apache/PHP/php-mysqlnd/MariaDB, creates a DB + user with a random password, downloads WordPress,
   writes `wp-config.php` with fresh salts from `api.wordpress.org/secret-key`, sets permissions, runs the
   installer with WP-CLI, and starts the services.
7. **Elastic IP**: allocated (or reused) and associated.
8. **Route 53**: `UPSERT` of A records for the apex and `www` names → Elastic IP. The script waits until the change is `INSYNC`.
9. **Health**: waits for EC2 status checks, then polls `http://<domain>` (pinned to the Elastic IP with
   `curl --resolve`, so it doesn't depend on DNS caches) until WordPress answers.
10. **Public DNS check**: asks 8.8.8.8 whether your names resolve to the Elastic IP. If not, it explains why
    (e.g. the registration is on `clientHold`).
11. **`--https`** (optional): certbot via SSM Run Command, HTTP→HTTPS redirect, auto-renewal, WordPress URLs → https.

### 02-attach-rds.sh
1. Finds the instance from script 1 **by tag**, and checks it is running and Online in SSM.
2. **db-sg**: inbound 3306 only from **web-sg** (security-group reference).
3. **DB subnet group** from the default VPC subnets (needs ≥2 AZs).
4. **Credentials** → SSM Parameter Store `/<PROJECT>/db/*`. Passwords are random SecureStrings; RDS receives
   the master password via a private temp file, never on the command line.
5. **RDS MySQL 8.4**, db.t3.micro, 20 GB gp3, encrypted, single-AZ, not public, 1-day backups, in the web server's AZ.
6. **Migration via SSM Run Command** (`remote/migrate-to-rds.sh`):
   back up `wp-config.php` → `mysqldump` → create the DB and a least-privilege `wp_app` user (`REQUIRE SSL`) → import →
   update `DB_HOST/DB_NAME/DB_USER/DB_PASSWORD` (+ TLS flag) → test PHP→RDS → stop & disable MariaDB → restart Apache.
   **If any step fails, the original `wp-config.php` is restored and MariaDB restarted**, so the site stays up.
7. **Verify**: queries RDS from the instance (server, version, TLS, `wp_` tables, siteurl) and loads the site
   from your machine. If that fails, it rolls back automatically.

### 99-teardown.sh
Route 53 records (first, so DNS never points at a released IP) → RDS → Elastic IP → EC2 → db-sg, web-sg →
DB subnet group → key pair → SSM parameters → IAM role/profile → `state.env`. Only resources carrying your
`Project` tag (or our exact names) are touched. The hosted zone is kept.

## What each AWS service does here

| Service | Role in this project |
|---|---|
| **Amazon EC2** | The virtual server running Apache, PHP-FPM and WordPress. |
| **AMI + SSM public parameter** | AWS publishes the newest Amazon Linux 2023 AMI ID in a public parameter, so you always launch a patched OS. |
| **EC2 user-data / cloud-init** | A first-boot script that turns a blank server into a WordPress server automatically. |
| **Amazon EBS (gp3)** | The server's encrypted disk. |
| **Security groups** | Stateful firewalls. web-sg exposes 80/443 (22 to one IP). db-sg accepts 3306 **only from members of web-sg**, which keeps working if IPs change or more web servers are added. |
| **Elastic IP** | A static public IPv4 address, so DNS doesn't break on stop/start. |
| **Amazon Route 53** | DNS: the hosted zone maps the apex and `www` names to the Elastic IP. |
| **AWS IAM (role + instance profile)** | Temporary, auto-rotated credentials for the server instead of stored access keys. Least privilege. |
| **Systems Manager: Run Command** | Runs the migration on the server without SSH or open ports, and logs every run. |
| **Systems Manager: Parameter Store** | Stores passwords as KMS-encrypted SecureStrings, so no secret is in code, user-data, terminal output or git. |
| **AWS KMS** | Encrypts the SecureStrings, EBS volume and RDS storage (AWS-managed keys). |
| **Amazon RDS for MySQL** | Managed database: backups, patching, monitoring. Private, with no public endpoint. |
| **DB subnet group** | The subnets RDS may use. Must span ≥2 AZs so a Multi-AZ standby can be added later. |
| **Resource tags** | `Project=<PROJECT>` on everything: idempotent lookups, cost tracking, safe teardown. |

## Security choices
- No secrets in scripts, user-data, Run Command parameters, process arguments or terminal output.
- SSH limited to one /32. IMDSv2 required. EBS and RDS encrypted at rest. EC2→RDS uses TLS with certificate verification.
- WordPress uses its own least-privilege DB user, not the RDS master user.
- The local MariaDB is bound to 127.0.0.1, and disabled after the migration.

## Production hardening (out of scope for this template)
Multi-AZ RDS, deletion protection and final snapshots, an Application Load Balancer + Auto Scaling group,
media offloaded to S3/CloudFront, AWS WAF, and AWS Backup.

## Cost
About **$0.03/hour** with no Free Tier coverage (EC2 t3.micro, RDS db.t3.micro, public IPv4, a little storage),
plus $0.50/month for the hosted zone. **Run `./99-teardown.sh` when you're done.**

## Troubleshooting
- **Site works via the Elastic IP but the domain doesn't resolve:** check the *registration*:
  `aws route53domains get-domain-detail --region us-east-1 --domain-name <domain> --query StatusList`.
  `clientHold` usually means the registrant email isn't verified. Until it's fixed, test with
  `curl --resolve <domain>:80:<elastic-ip> http://<domain>/`.
- **WordPress not answering after 10 min:** run `aws ssm start-session --target <id>`, then
  `sudo cat /var/log/wordpress-bootstrap.log`.
- **SSH times out:** your public IP changed. Re-run `./01-deploy-wordpress.sh` to update the rule.
- **Credentials expired:** run `aws login` again.
