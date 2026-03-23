# SpamAssassin x402 Email Check

This setup lets SpamAssassin call your paid endpoint:

- `https://app.cusethejuice.com/api/bots/email-check?email=...`

with a Python helper that pays x402 using an EVM private key on Base.

## 1) Wallet requirements

Operator wallet must have:

- Base ETH (gas)
- Base USDC (payment asset)

Export the private key for the process running `spamd`:

```bash
export EVM_PRIVATE_KEY=0x...
# or:
export BASE_WALLET_PRIVATE_KEY=0x...
```

## 2) Install Python deps

```bash
python3 -m pip install -r spamassassin/requirements-x402-client.txt
```

## 3) Place files for SpamAssassin

Copy these files to your SpamAssassin host:

- `spamassassin/CTJEmailCheck.pm`
- `spamassassin/ctj-email-check.cf`
- `spamassassin/x402_email_check_client.py`

Set executable bit for the script:

```bash
chmod +x /etc/mail/spamassassin/x402_email_check_client.py
```

## 4) Configure `.cf`

In your active SpamAssassin config:

```cf
loadplugin Mail::SpamAssassin::Plugin::CTJEmailCheck /etc/mail/spamassassin/CTJEmailCheck.pm

ctj_email_check_script_python_bin /usr/bin/python3
ctj_email_check_script_path /etc/mail/spamassassin/x402_email_check_client.py
ctj_email_check_script_endpoint https://app.cusethejuice.com/api/bots/email-check
ctj_email_check_timeout_seconds 2

header CTJ_EMAIL_CHECK_FROM eval:ctj_email_check_header('From')
score CTJ_EMAIL_CHECK_FROM 2.5
describe CTJ_EMAIL_CHECK_FROM Invalid email syntax detected in From header
```

## 5) Validate

Run:

```bash
spamassassin --lint
```

If lint passes, restart `spamd`.

## Notes

- Plugin flow order:
  1) Python x402 script (if configured)
  2) direct API call (if configured)
  3) local fallback validator
- If the script errors or payment cannot be completed, plugin falls back to local validation so mail flow does not break.
