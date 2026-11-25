"""
The rules the application sets for the homeserver, which Synapse has no setting for.

Only the application creates spaces. A space is a room of type m.space, and the application's bot
is the one user who may create one, so every space on the homeserver is one the application knows.
Any other room, such as a direct message or a group room, is created freely.

No room is encrypted, until `encryption` is set. Clients are told so in the well-known file, and
this holds it for a client that does not listen: the encryption a new room asks for is left out,
and turning it on later is refused.

With `encryption` set, a room outside the spaces is always encrypted and a room of a space is
encrypted when the application says so. A room anyone but the bot makes is a direct message or a
group room, and is made encrypted whether it asks to be or not. In a room the bot is in, which is
a space or a room of one, only the bot turns it on, as it makes the room or later. A room that is
encrypted stays so: its encryption is not set again and not removed, and a message or sticker
that is not encrypted is refused in it.

A room the bot is not in that is not encrypted takes no new members until it is. Synapse keeps a
room whose creation failed halfway, with its creator in it and nothing of what was to follow, the
encryption included. So does a room from before `encryption` was set, and one that replaces an
unencrypted room. Nobody is invited to such a room, joins it or knocks on it before one who may
encrypts it.

In a room the bot is in, only the bot invites. The bot is in the spaces and their rooms, which it
makes, and who is in those is decided in the application. The levels of such a room already keep
its members from inviting, and this holds it whatever the levels say. A room the bot is not in,
such as a direct message or a group room, is its members' own.

Loaded from homeserver.yaml:

    modules:
        - module: omegaweb_rules.OmegawebRules
          config:
              space_creator: "@omegaweb:example.org"
              encryption: false
"""

from typing import Any, Optional

from synapse.api.errors import Codes, SynapseError
from synapse.events import EventBase
from synapse.module_api import ModuleApi
from synapse.module_api.errors import ConfigError
from synapse.types import Requester, StateMap

SPACE = "m.space"
CREATE = "m.room.create"
ENCRYPTION = "m.room.encryption"
MEMBER = "m.room.member"
REDACTION = "m.room.redaction"
MEGOLM = "m.megolm.v1.aes-sha2"
ENCRYPTED_IN_AN_ENCRYPTED_ROOM = ("m.room.message", "m.sticker")
ENTERING = ("invite", "join", "knock")


class OmegawebRules:
    def __init__(self, config: dict[str, Any], api: ModuleApi):
        self._space_creator = config["space_creator"]
        self._encryption = config["encryption"]
        api.register_third_party_rules_callbacks(
            on_create_room=self.on_create_room,
            check_event_allowed=self.check_event_allowed,
        )

    @staticmethod
    def parse_config(config: Any) -> dict[str, Any]:
        space_creator = (config or {}).get("space_creator")
        if not isinstance(space_creator, str) or not space_creator.startswith("@"):
            raise ConfigError("space_creator must be the user id of the one who may create spaces")
        encryption = (config or {}).get("encryption", False)
        if not isinstance(encryption, bool):
            raise ConfigError("encryption must be true or false")
        return {"space_creator": space_creator, "encryption": encryption}

    async def on_create_room(
        self, requester: Requester, request_content: dict[str, Any], is_requester_admin: bool
    ) -> None:
        by_bot = requester.user.to_string() == self._space_creator
        creation_content = request_content.get("creation_content") or {}
        if creation_content.get("type") == SPACE and not by_bot:
            raise SynapseError(403, "Spaces are created in omegaweb", Codes.FORBIDDEN)

        # Synapse builds the room from this same dict after the callback, so what is taken out
        # or put in here is what the room gets.
        initial_state = request_content.get("initial_state")
        if not self._encryption:
            if isinstance(initial_state, list):
                request_content["initial_state"] = _without_encryption(initial_state)
        elif not by_bot:
            if not isinstance(initial_state, (list, type(None))):
                raise SynapseError(400, "initial_state must be a list", Codes.BAD_JSON)
            request_content["initial_state"] = _without_encryption(initial_state or []) + [
                {"type": ENCRYPTION, "state_key": "", "content": {"algorithm": MEGOLM}}
            ]

    async def check_event_allowed(
        self, event: EventBase, state_events: StateMap[EventBase]
    ) -> tuple[bool, Optional[dict]]:
        if self._is_invite_past_the_application(event, state_events):
            raise SynapseError(403, "Members are managed in omegaweb", Codes.FORBIDDEN)
        if not self._encryption:
            if event.type == ENCRYPTION:
                raise SynapseError(403, "No room is encrypted", Codes.FORBIDDEN)
            return True, None

        encryption = state_events.get((ENCRYPTION, ""))
        if event.type == ENCRYPTION:
            self._check_may_encrypt(event, state_events)
        elif encryption is None:
            if self._is_entering_past_encryption(event, state_events):
                raise SynapseError(403, "This room takes no members until it is encrypted", Codes.FORBIDDEN)
        elif event.type == REDACTION and event.redacts == encryption.event_id:
            raise SynapseError(403, "A room that is encrypted stays so", Codes.FORBIDDEN)
        elif event.type in ENCRYPTED_IN_AN_ENCRYPTED_ROOM:
            raise SynapseError(403, "This room is encrypted, and takes no message that is not", Codes.FORBIDDEN)
        return True, None

    def _check_may_encrypt(self, event: EventBase, state_events: StateMap[EventBase]) -> None:
        if (ENCRYPTION, "") in state_events:
            raise SynapseError(403, "A room that is encrypted stays so", Codes.FORBIDDEN)
        if event.sender != self._space_creator and self._is_bot_in(state_events):
            raise SynapseError(403, "Whether this room is encrypted is decided in omegaweb", Codes.FORBIDDEN)
        by_bot = event.sender == self._space_creator
        if event.content.get("algorithm") != MEGOLM or (not by_bot and len(event.content) > 1):
            raise SynapseError(400, f"A room is encrypted with {MEGOLM} and nothing more is said of it", Codes.BAD_JSON)

    def _is_entering_past_encryption(self, event: EventBase, state_events: StateMap[EventBase]) -> bool:
        if event.type != MEMBER or event.content.get("membership") not in ENTERING:
            return False
        created = state_events.get((CREATE, ""))
        is_creator = created is not None and event.state_key == created.sender
        member = state_events.get((MEMBER, event.state_key))
        is_in_already = member is not None and member.content.get("membership") == "join"
        return not is_creator and not is_in_already and not self._is_bot_in(state_events)

    def _is_invite_past_the_application(self, event: EventBase, state_events: StateMap[EventBase]) -> bool:
        is_invite = event.type == MEMBER and event.content.get("membership") == "invite"
        return is_invite and event.sender != self._space_creator and self._is_bot_in(state_events)

    def _is_bot_in(self, state_events: StateMap[EventBase]) -> bool:
        bot = state_events.get((MEMBER, self._space_creator))
        return bot is not None and bot.content.get("membership") == "join"


def _without_encryption(initial_state: list) -> list:
    return [event for event in initial_state if not (isinstance(event, dict) and event.get("type") == ENCRYPTION)]
