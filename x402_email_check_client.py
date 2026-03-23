#!/usr/bin/env python3
"""
Paid x402 client for CuseTheJuice email-check endpoint.

This script is intended to be invoked by SpamAssassin plugin CTJEmailCheck.pm.
It tries to fetch `GET {endpoint}?email=...` with automatic x402 payment handling.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import base64
from typing import Any


def _emit(payload: dict[str, Any], exit_code: int = 0) -> int:
    print(json.dumps(payload, separators=(",", ":")))
    return exit_code


def _load_x402_stack() -> tuple[Any, Any, Any, Any]:
    from eth_account import Account  # type: ignore
    from x402 import x402ClientSync  # type: ignore
    from x402.mechanisms.evm import EthAccountSigner  # type: ignore
    from x402.mechanisms.evm.exact.register import register_exact_evm_client  # type: ignore

    return Account, x402ClientSync, (EthAccountSigner, register_exact_evm_client)


def _parse_payment_required_headers(response: Any) -> tuple[dict[str, Any], str | None]:
    """
    Extract and parse x402 PaymentRequired JSON from 402 responses.

    The server may send it as:
    - PAYMENT-REQUIRED-JSON (JSON string)
    - PAYMENT-REQUIRED (base64-encoded payload)
    """
    # requests lower-cases header keys
    header_json = None
    for k in ("payment-required-json", "PAYMENT-REQUIRED-JSON", "PAYMENT_REQUIRED_JSON"):
        header_json = response.headers.get(k)
        if header_json:
            break

    if header_json:
        return json.loads(header_json), "payment-required-json"

    header_b64 = None
    for k in ("payment-required", "PAYMENT-REQUIRED", "X-PAYMENT-REQUIRED"):
        header_b64 = response.headers.get(k)
        if header_b64:
            break

    if not header_b64:
        raise ValueError("Missing payment-required headers in 402 response")

    decoded = base64.b64decode(header_b64).decode("utf-8")
    return json.loads(decoded), "payment-required"


def _massage_payment_required_for_sdk(payment_required: dict[str, Any]) -> dict[str, Any]:
    """
    The endpoint returns PaymentRequiredV1 with:
      - accepts[0].amount
      - top-level resource{...}

    The x402 SDK expects:
      - accepts[0].maxAmountRequired
      - accepts[0].resource
    """
    payment_required = dict(payment_required)  # shallow copy
    accepts = payment_required.get("accepts")
    if isinstance(accepts, list) and accepts:
        a0 = dict(accepts[0])

        if "maxAmountRequired" not in a0 and "amount" in a0:
            a0["maxAmountRequired"] = a0.get("amount")

        if "resource" not in a0 and "resource" in payment_required:
            # Prefer string URL if available.
            res = payment_required.get("resource")
            if isinstance(res, dict) and "url" in res:
                a0["resource"] = res["url"]
            else:
                a0["resource"] = res

        accepts = list(accepts)
        accepts[0] = a0
        payment_required["accepts"] = accepts

    return payment_required


def _extract_x_payment_value(payment_payload: Any) -> str | None:
    """
    Best-effort extraction of the header value to send back to the server.

    The x402 client typically returns the already-encoded header value.
    """
    if isinstance(payment_payload, str):
        return payment_payload
    if isinstance(payment_payload, dict):
        # try common keys
        for k in ("X-PAYMENT", "x-payment", "xPayment", "x_payment", "payment", "payload", "value"):
            v = payment_payload.get(k)
            if isinstance(v, str) and v:
                return v
        # if dict has a single string value, use it
        string_values = [v for v in payment_payload.values() if isinstance(v, str) and v]
        if len(string_values) == 1:
            return string_values[0]
    # fallback: maybe an object with attributes
    for attr in ("x_payment", "xPayment", "value", "payload"):
        v = getattr(payment_payload, attr, None)
        if isinstance(v, str) and v:
            return v
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Call CuseTheJuice email-check with x402 payment")
    parser.add_argument("--email", required=True, help="Email address to validate")
    parser.add_argument(
        "--endpoint",
        default="https://app.cusethejuice.com/api/bots/email-check",
        help="x402 endpoint URL (without query email)",
    )
    parser.add_argument("--timeout", type=float, default=2.0, help="Request timeout in seconds")
    args = parser.parse_args()

    pk = os.getenv("EVM_PRIVATE_KEY") or os.getenv("BASE_WALLET_PRIVATE_KEY")
    if not pk:
        return _emit(
            {
                "ok": False,
                "valid": None,
                "error": "Missing EVM_PRIVATE_KEY or BASE_WALLET_PRIVATE_KEY",
            },
            2,
        )

    try:
        Account, x402ClientSync, evm_bits = _load_x402_stack()
        EthAccountSigner, register_exact_evm_client = evm_bits
    except Exception as exc:  # pragma: no cover
        return _emit(
            {
                "ok": False,
                "valid": None,
                "error": f"Python x402 dependencies missing: {exc}",
            },
            2,
        )

    try:
        account = Account.from_key(pk)
        client = x402ClientSync()
        register_exact_evm_client(client, EthAccountSigner(account))

        endpoint = args.endpoint
        sep = "&" if "?" in endpoint else "?"
        url = f"{endpoint}{sep}email={args.email}"

        import requests  # type: ignore

        # 1) Try without payment first.
        with requests.Session() as session:
            response = session.get(url, timeout=args.timeout, headers={"Accept": "application/json"})

            status = int(response.status_code)
            if status == 402:
                # 2) Handle payment required by reshaping payment-required-json for the SDK,
                #    generating a signed X-PAYMENT payload, and retrying.
                try:
                    payment_required, header_src = _parse_payment_required_headers(response)
                    payment_required = _massage_payment_required_for_sdk(payment_required)
                    payment_payload = client.create_payment_payload(payment_required)  # type: ignore[attr-defined]
                    x_payment = _extract_x_payment_value(payment_payload)
                    if not x_payment:
                        return _emit(
                            {
                                "ok": False,
                                "valid": None,
                                "http_status": 402,
                                "error": f"Could not extract X-PAYMENT value from x402 payload (source={header_src})",
                            },
                            1,
                        )

                    response = session.get(
                        url,
                        timeout=args.timeout,
                        headers={"Accept": "application/json", "X-PAYMENT": x_payment},
                    )
                    status = int(response.status_code)
                except Exception as exc:
                    return _emit(
                        {
                            "ok": False,
                            "valid": None,
                            "http_status": 402,
                            "error": f"Failed to handle payment: {exc}",
                        },
                        1,
                    )

            if status != 200:
                return _emit(
                    {
                        "ok": False,
                        "valid": None,
                        "http_status": status,
                        "error": f"Unexpected response status {status}",
                    },
                    1,
                )

        body = response.json()
        result = body.get("result") if isinstance(body, dict) else None
        valid = result.get("valid") if isinstance(result, dict) else None
        if not isinstance(valid, bool):
            return _emit(
                {
                    "ok": False,
                    "valid": None,
                    "http_status": status,
                    "error": "Missing result.valid in JSON response",
                },
                1,
            )

        return _emit(
            {
                "ok": True,
                "valid": valid,
                "http_status": status,
                "normalizedEmail": result.get("normalizedEmail"),
                "issues": result.get("issues", []),
                "source": "x402-python-client",
            }
        )
    except Exception as exc:
        return _emit({"ok": False, "valid": None, "error": str(exc)}, 1)


if __name__ == "__main__":
    sys.exit(main())

