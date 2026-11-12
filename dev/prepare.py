"""
Writes what Synapse and MAS read from files under /secrets, which production gets from its secret
store. The values that are fixed in development come from the environment, see compose.yaml. The
keys MAS encrypts and signs with are made here, once, and kept on the volume, so a restart keeps
every session. Run in the Synapse image, which has the cryptography library; the MAS image has no
shell to make them in.
"""

import os
import secrets

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa

DIRECTORY = "/secrets"
KEYS = os.path.join(DIRECTORY, "mas-keys")

# The file each value is read from, by the variable that holds it here.
FIXED = {
    "SYNAPSE_MACAROON_SECRET": "synapse-macaroon",
    "SYNAPSE_FORM_SECRET": "synapse-form",
    "MAS_SHARED_SECRET": "mas-shared",
    "CHAT_MAS_CLIENT_SECRET": "mas-client-secret",
    "PGPASSWORD": "db-password",
}


def write(path: str, content: bytes) -> None:
    with open(path, "wb") as file:
        file.write(content)
    # Synapse and MAS each run as a user of their own and only read them.
    os.chmod(path, 0o644)


def pem(key) -> bytes:
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )


for variable, name in FIXED.items():
    write(os.path.join(DIRECTORY, name), os.environ[variable].encode())

if not os.path.exists(os.path.join(DIRECTORY, "mas-encryption")):
    os.makedirs(KEYS, exist_ok=True)
    write(os.path.join(KEYS, "rsa.pem"), pem(rsa.generate_private_key(public_exponent=65537, key_size=2048)))
    write(os.path.join(KEYS, "ec.pem"), pem(ec.generate_private_key(ec.SECP256R1())))
    # Written last, so a run that was cut short starts over.
    write(os.path.join(DIRECTORY, "mas-encryption"), secrets.token_hex(32).encode())
