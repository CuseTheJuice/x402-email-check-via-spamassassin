# x402 Email Check via SpamAssassin

SpamAssassin plugin + Python client that validates email addresses in headers using:

1. paid x402 endpoint call (preferred), then
2. optional direct API call, then
3. local validation fallback.

Repository: [CuseTheJuice/x402-email-check-via-spamassassin](https://github.com/CuseTheJuice/x402-email-check-via-spamassassin)

## What this does

- Adds SpamAssassin rules that inspect `From` and `Reply-To`.
- Calls a Python helper that can pay the x402 paywall on Base and fetch validation results.
- Fails safe: if network/payment/dependency issues happen, plugin falls back to local validation so mail flow keeps moving.

---

## Files in this repo

- `CTJEmailCheck.pm` - SpamAssassin plugin
- `ctj-email-check.cf` - rule/config template
- `x402_email_check_client.py` - paid x402 client used by plugin
- `requirements-x402-client.txt` - Python dependencies for the x402 client
- `install_spamassassin_x402.sh` - automated installer (remote runnable)

---

## Prerequisites

- Linux host running SpamAssassin (`spamd`)
- root/sudo access
- Python >= 3.10 (required by the `x402` Python SDK)
- Wallet private key for x402 payment available to the `spamd` runtime:
  - `EVM_PRIVATE_KEY=0x...` (preferred), or
  - `BASE_WALLET_PRIVATE_KEY=0x...`
- Wallet has Base native gas and Base USDC (payment)

---

## Quick install (remote, one command)

Run this on the SpamAssassin host:

```bash
curl -fsSL https://raw.githubusercontent.com/CuseTheJuice/x402-email-check-via-spamassassin/main/install_spamassassin_x402.sh | sudo bash
```

This installer:

- installs base dependencies (`git`, `spamassassin`, build tools, Python) when possible
- ensures Python 3.10+ is available for the `x402` client
- clones this repo
- installs plugin/client files into `/etc/mail/spamassassin`
- installs Python requirements
- appends a managed config block into `/etc/mail/spamassassin/local.cf` if not already present
- runs `spamassassin --lint`
- restarts `spamd`/`spamassassin` service if detected

### Optional installer overrides

Use env vars in front of the command:

```bash
REPO_REF=main \
SA_DIR=/etc/mail/spamassassin \
SA_LOCAL_CF=/etc/mail/spamassassin/local.cf \
# Optional: override only if you already have Python 3.10+ installed
# (example: /usr/bin/python3.10). If unset, the installer will try to find/install it.
ENDPOINT_URL=https://app.cusethejuice.com/api/bots/email-check \
TIMEOUT_SECONDS=2 \
curl -fsSL https://raw.githubusercontent.com/CuseTheJuice/x402-email-check-via-spamassassin/main/install_spamassassin_x402.sh | sudo -E bash
```

---

## Post-install required step (important)

Make sure your SpamAssassin daemon process sees the wallet private key.

The installer tries to write it into your service's systemd `EnvironmentFile` (commonly `/etc/default/spamassassin`) if the key is not already present.

If you ran the installer via `curl -fsSL ... | sudo bash` and it could not prompt (non-interactive), you must provide it ahead of time:

```bash
export BASE_WALLET_PRIVATE_KEY=0xYOUR_PRIVATE_KEY
curl -fsSL https://raw.githubusercontent.com/CuseTheJuice/x402-email-check-via-spamassassin/main/install_spamassassin_x402.sh | sudo -E bash
```

To verify, check:

```bash
sudo rg -n "EVM_PRIVATE_KEY=|BASE_WALLET_PRIVATE_KEY=" /etc/default/spamassassin || true
sudo systemctl restart spamassassin || sudo systemctl restart spamd || true
```

---

## Manual install (if you do not want curl|bash)

1. Install dependencies:

```bash
sudo apt-get update
sudo apt-get install -y spamassassin python3 python3-pip
# x402 requires Python >= 3.10
sudo apt-get install -y python3.10 python3.10-venv python3.10-dev || true
python3.10 -m ensurepip --upgrade || true
python3.10 -m pip install --upgrade pip
python3.10 -m pip install -r requirements-x402-client.txt
```

2. Copy files:

```bash
sudo install -m 0644 CTJEmailCheck.pm /etc/mail/spamassassin/CTJEmailCheck.pm
sudo install -m 0644 ctj-email-check.cf /etc/mail/spamassassin/ctj-email-check.cf
sudo install -m 0755 x402_email_check_client.py /etc/mail/spamassassin/x402_email_check_client.py
```

3. Add to `/etc/mail/spamassassin/local.cf`:

```cf
loadplugin Mail::SpamAssassin::Plugin::CTJEmailCheck /etc/mail/spamassassin/CTJEmailCheck.pm
ctj_email_check_script_python_bin /usr/bin/python3.10
ctj_email_check_script_path /etc/mail/spamassassin/x402_email_check_client.py
ctj_email_check_script_endpoint https://app.cusethejuice.com/api/bots/email-check
ctj_email_check_timeout_seconds 2

header CTJ_EMAIL_CHECK_FROM eval:ctj_email_check_header('From')
score CTJ_EMAIL_CHECK_FROM 2.5
describe CTJ_EMAIL_CHECK_FROM Invalid email syntax detected in From header

header CTJ_EMAIL_CHECK_REPLYTO eval:ctj_email_check_header('Reply-To')
score CTJ_EMAIL_CHECK_REPLYTO 1.5
describe CTJ_EMAIL_CHECK_REPLYTO Invalid email syntax detected in Reply-To header
```

4. Validate and restart:

```bash
sudo spamassassin --lint
sudo systemctl restart spamd || sudo systemctl restart spamassassin
```

---

## Verifying it works

1. Lint check passes:

```bash
spamassassin --lint
```

2. Direct script test:

```bash
EVM_PRIVATE_KEY=0x... /usr/bin/python3 /etc/mail/spamassassin/x402_email_check_client.py \
  --email invalid..email@example.com \
  --endpoint https://app.cusethejuice.com/api/bots/email-check \
  --timeout 2
```

3. Check mail logs for SpamAssassin hits:

- `CTJ_EMAIL_CHECK_FROM`
- `CTJ_EMAIL_CHECK_REPLYTO`

---

## Operational notes

- If the x402 request fails (dependency, payment, timeout, non-200), plugin falls back to local validation.
- `ctj_email_check_timeout_seconds` defaults to `2`.
- Script endpoint defaults to `https://app.cusethejuice.com/api/bots/email-check`.

---

## Security notes

- Treat private keys as secrets. Do not hardcode keys in repo files.
- Prefer injecting key via service environment/secrets manager.
- Run with least-privilege host access where possible.

---

## License

MIT (see `LICENSE`)
