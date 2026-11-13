"""
The rules the application sets for the homeserver, which Synapse has no setting for.

Only the application creates spaces. A space is a room of type m.space, and the application's bot
is the one user who may create one, so every space on the homeserver is one the application knows.
Any other room, such as a direct message or a group room, is created freely.

No room is encrypted. Clients are told so in the well-known file, and this holds it for a client
that does not listen: the encryption a new room asks for is left out, and turning it on later is
refused.

In a room the bot is in, only the bot invites. The bot is in the spaces and in the rooms a space
holds, and who is in those is decided in the application. The levels of such a room already keep
its members from inviting, but the one who made a room outranks its levels, and this holds it for
them too. A room the bot is not in, such as a direct message or a group room, is its members' own.

Loaded from homeserver.yaml:

    modules:
        - module: omegaweb_rules.OmegawebRules
          config:
              space_creator: "@omegaweb:example.org"
"""

from typing import Any, Optional

from synapse.api.errors import Codes, SynapseError
from synapse.events import EventBase
from synapse.module_api import ModuleApi
from synapse.module_api.errors import ConfigError
from synapse.types import Requester, StateMap

SPACE = "m.space"
ENCRYPTION = "m.room.encryption"
MEMBER = "m.room.member"


class OmegawebRules:
    def __init__(self, config: dict[str, str], api: ModuleApi):
        self._space_creator = config["space_creator"]
        api.register_third_party_rules_callbacks(
            on_create_room=self.on_create_room,
            check_event_allowed=self.check_event_allowed,
        )

    @staticmethod
    def parse_config(config: Any) -> dict[str, str]:
        space_creator = (config or {}).get("space_creator")
        if not isinstance(space_creator, str) or not space_creator.startswith("@"):
            raise ConfigError("space_creator must be the user id of the one who may create spaces")
        return {"space_creator": space_creator}

    async def on_create_room(
        self, requester: Requester, request_content: dict[str, Any], is_requester_admin: bool
    ) -> None:
        creation_content = request_content.get("creation_content") or {}
        if creation_content.get("type") == SPACE and requester.user.to_string() != self._space_creator:
            raise SynapseError(403, "Spaces are created in omegaweb", Codes.FORBIDDEN)

        # Synapse builds the room from this same dict after the callback, so what is taken out
        # here is not in the room.
        initial_state = request_content.get("initial_state")
        if isinstance(initial_state, list):
            request_content["initial_state"] = [
                event for event in initial_state
                if not (isinstance(event, dict) and event.get("type") == ENCRYPTION)
            ]

    async def check_event_allowed(
        self, event: EventBase, state_events: StateMap[EventBase]
    ) -> tuple[bool, Optional[dict]]:
        if self._is_invite_past_the_application(event, state_events):
            raise SynapseError(403, "Members are managed in omegaweb", Codes.FORBIDDEN)
        return event.type != ENCRYPTION, None

    def _is_invite_past_the_application(self, event: EventBase, state_events: StateMap[EventBase]) -> bool:
        is_invite = event.type == MEMBER and event.content.get("membership") == "invite"
        if not is_invite or event.sender == self._space_creator:
            return False
        bot = state_events.get((MEMBER, self._space_creator))
        return bot is not None and bot.content.get("membership") == "join"
