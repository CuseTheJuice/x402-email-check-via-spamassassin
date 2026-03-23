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
from typing import Any


def _emit(payload: dict[str, Any], exit_code: int = 0) -> int:
    print(json.dumps(payload, separators=(",", ":")))
    return exit_code


def _load_x402_stack() -> tuple[Any, Any, Any, Any]:
    from eth_account import Account  # type: ignore
    from x402 import x402ClientSync  # type: ignore
    from x402.http.clients import x402_requests  # type: ignore
    from x402.mechanisms.evm import EthAccountSigner  # type: ignore
    from x402.mechanisms.evm.exact.register import register_exact_evm_client  # type: ignore

    return Account, x402ClientSync, x402_requests, (EthAccountSigner, register_exact_evm_client)


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
        Account, x402ClientSync, x402_requests, evm_bits = _load_x402_stack()
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

        with x402_requests(client) as session:
            response = session.get(url, timeout=args.timeout, headers={"Accept": "application/json"})

        status = int(response.status_code)
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

