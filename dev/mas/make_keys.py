"""
Makes the keys MAS needs, once: the key it encrypts what it stores with, and the keys it signs
tokens with. They are kept on a volume, so a restart keeps every session. Run in the Synapse image,
which has the cryptography library; the MAS image has no shell to make them in.
"""

import os
import secrets

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa

DIRECTORY = "/secrets"
KEYS = os.path.join(DIRECTORY, "keys")


def write(path: str, content: bytes) -> None:
    with open(path, "wb") as file:
        file.write(content)
    # MAS runs as a user of its own and only reads them.
    os.chmod(path, 0o644)


def pem(key) -> bytes:
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )


if not os.path.exists(os.path.join(DIRECTORY, "encryption")):
    os.makedirs(KEYS, exist_ok=True)
    write(os.path.join(KEYS, "rsa.pem"), pem(rsa.generate_private_key(public_exponent=65537, key_size=2048)))
    write(os.path.join(KEYS, "ec.pem"), pem(ec.generate_private_key(ec.SECP256R1())))
    # Written last, so a run that was cut short starts over.
    write(os.path.join(DIRECTORY, "encryption"), secrets.token_hex(32).encode())
