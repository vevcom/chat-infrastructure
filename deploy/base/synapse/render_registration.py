"""
Writes the application service registration Synapse reads, from the template beside this file and
the environment: the two tokens, where Synapse sends events, and the server name as a regular
expression. Run before Synapse starts, since Synapse reads the registration once.
"""

import os
import re
import string

TEMPLATE = "/config/appservice.yaml"
REGISTRATION = "/registration/appservice.yaml"

values = {
    "CHAT_AS_TOKEN": os.environ["CHAT_AS_TOKEN"],
    "CHAT_HS_TOKEN": os.environ["CHAT_HS_TOKEN"],
    # Where the application takes the events. Unset, Synapse sends none.
    "CHAT_APPSERVICE_URL": os.environ.get("CHAT_APPSERVICE_URL") or "null",
    "CHAT_SERVER_NAME_REGEX": re.escape(os.environ["CHAT_SERVER_NAME"]).replace("\\", "\\\\"),
}

with open(TEMPLATE) as template:
    registration = string.Template(template.read()).substitute(values)
with open(REGISTRATION, "w") as file:
    file.write(registration)
