import argparse
import functools
import getpass
import json
import os
import pathlib
import secrets
import subprocess
import sys
from typing import Callable

import bcrypt

DOMAIN = "maydayelectronics.com"
REMOTE_HOST = os.environ.get("REMOTE_HOST", f"root@{DOMAIN}")
REMOTE_PORT = os.environ.get("REMOTE_PORT", "22")
SOPS_FILE = os.environ.get("SOPS_FILE", "secrets/secrets.yaml")

USER_ERRORS = (subprocess.CalledProcessError, RuntimeError, ValueError)


def _ssh() -> list[str]:
    return ["ssh", "-n", "-p", REMOTE_PORT, REMOTE_HOST]


@functools.lru_cache(maxsize=1)
def _sops_data() -> dict:
    result = subprocess.run(
        ["sops", "-d", "--output-type", "json", SOPS_FILE],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def list_mailboxes() -> list[str]:
    return sorted(_sops_data().get("mail", {}).keys())


def load_sops_value(*keys: str):
    d = _sops_data()
    for k in keys:
        if not isinstance(d, dict) or k not in d:
            return None
        d = d[k]
    return d


def _sops_path(*keys: str) -> str:
    return "".join(f'["{k}"]' for k in keys)


def write_sops(path: str, value) -> None:
    subprocess.run(
        ["sops", "set", "--value-stdin", SOPS_FILE, path],
        input=json.dumps(value),
        check=True,
        text=True,
    )
    _sops_data.cache_clear()


def bcrypt_hash(plain: str) -> str:
    return bcrypt.hashpw(plain.encode(), bcrypt.gensalt(12)).decode()


def _doveadm(
    addr: str, pw: str, *subcmd: str, capture: bool = False
) -> subprocess.CompletedProcess:
    return subprocess.run(
        _ssh()
        + ["doveadm", "-o", f"plugin/mail_crypt_private_password={pw}"]
        + list(subcmd)
        + ["-u", addr, "-U"],
        capture_output=capture,
        text=True,
    )


def prompt_password(label: str, confirm: bool = False) -> str:
    # getpass.getpass opens /dev/tty directly and hangs when there's no
    # controlling terminal (e.g. piped stdin inside a nixos test VM).
    # Fall back to stdin so non-interactive invocations work.
    def read(lbl: str) -> str:
        if sys.stdin.isatty():
            return getpass.getpass(f"{lbl}: ")
        return sys.stdin.readline().rstrip("\n")

    pw = read(label)
    if confirm:
        pw2 = read("Confirm")
        if pw != pw2:
            raise ValueError("passwords do not match")
    return pw


def addr_of(mbx: str) -> str:
    return f"{mbx}@{DOMAIN}"


def do_set_password(mbx: str) -> None:
    new = prompt_password("New password", confirm=True)
    write_sops(_sops_path("mail", mbx, "hashedPassword"), bcrypt_hash(new))
    if mbx == "ghost":
        write_sops(_sops_path("ghost", "smtp_user"), f"ghost@{DOMAIN}")
        write_sops(_sops_path("ghost", "smtp_password"), new)
    print(f"Updated IMAP password for {mbx}. Run 'colmena apply mayday-vps' to deploy.")


def do_init_crypt_passwords() -> None:
    for mbx in list_mailboxes():
        pw = load_sops_value("mail", mbx, "cryptPassword")
        if pw is not None:
            print(f"{mbx}: cryptPassword already set, skipping")
            continue
        pw = secrets.token_urlsafe(24)
        write_sops(_sops_path("mail", mbx, "cryptPassword"), pw)
        print(f"{mbx}: generated cryptPassword")
    print("Run 'colmena apply' then 'mail-admin all' to bootstrap the doveadm keys.")


def do_bootstrap_key(mbx: str) -> None:
    addr = addr_of(mbx)
    pw = load_sops_value("mail", mbx, "cryptPassword")
    if pw is None:
        pw = secrets.token_urlsafe(24)
        write_sops(_sops_path("mail", mbx, "cryptPassword"), pw)
        print(f"generated new cryptPassword for {mbx} in sops")

    lst = _doveadm(addr, pw, "mailbox", "cryptokey", "list", capture=True)
    has_key = lst.returncode == 0 and "yes" in lst.stdout

    if not has_key:
        gen = _doveadm(addr, pw, "mailbox", "cryptokey", "generate", capture=True)
        if gen.returncode != 0:
            raise RuntimeError(
                f"failed to generate crypt key for {addr}: {gen.stderr.strip()}"
            )
        print(f"generated new crypt key for {addr}")
    else:
        # `cryptokey export` does not unwrap the key on dovecot 2.3 — it
        # succeeds even when the wrapping password is wrong. A no-op password
        # rewrap (old == new) forces an actual unwrap, failing loudly on drift.
        verify = subprocess.run(
            _ssh()
            + [
                "doveadm",
                "mailbox",
                "cryptokey",
                "password",
                "-u",
                addr,
                "-o",
                pw,
                "-n",
                pw,
            ],
            capture_output=True,
            text=True,
        )
        if verify.returncode != 0:
            raise RuntimeError(
                f"existing crypt key for {addr} does not unwrap with current "
                f"sops cryptPassword: {verify.stderr.strip()}"
            )
        print(f"verified existing crypt key unwraps for {addr}")

    print("Run 'colmena apply mayday-vps' to deploy the cryptPassword file.")


CHOICES: dict[str, Callable[[str], None]] = {
    "u": do_set_password,
    "b": do_bootstrap_key,
}


def do_all() -> None:
    for mbx in list_mailboxes():
        addr = addr_of(mbx)
        while True:
            choice = (
                input(
                    f"[{addr}] (u)pdate IMAP password, (b)ootstrap crypt key, (s)kip: "
                )
                .strip()
                .lower()
            )
            if choice == "s":
                break
            action = CHOICES.get(choice)
            if action is None:
                continue
            try:
                action(mbx)
            except USER_ERRORS as e:
                print(f"error: {e}", file=sys.stderr)
            break


def main() -> None:
    if not pathlib.Path("flake.nix").exists():
        print("error: run from the flake root (expected ./flake.nix)", file=sys.stderr)
        sys.exit(1)

    os.environ.setdefault(
        "SOPS_AGE_KEY_FILE",
        os.path.expanduser("~/.config/sops/age/mayday-vps.txt"),
    )

    parser = argparse.ArgumentParser(prog="mail-admin")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("set-password")
    sp.add_argument("mbx")
    sp = sub.add_parser("bootstrap-key")
    sp.add_argument("mbx")
    sub.add_parser("all")
    sub.add_parser("init-crypt-passwords")

    args = parser.parse_args()

    try:
        if args.cmd == "set-password":
            do_set_password(args.mbx)
        elif args.cmd == "bootstrap-key":
            do_bootstrap_key(args.mbx)
        elif args.cmd == "all":
            do_all()
        elif args.cmd == "init-crypt-passwords":
            do_init_crypt_passwords()
    except USER_ERRORS as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
