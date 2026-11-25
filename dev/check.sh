#!/bin/bash
# Checks the running development stack against what the root README says of it: who may create a
# space, that no room is encrypted, what the application may do, and what a user may not. Run from
# this directory once `docker compose up -d` has settled. It leaves two users, a space and its rooms
# behind; `docker compose down -v` clears them.
#
# `./check.sh encrypted` checks a stack started with compose.encrypted.yaml instead: what is
# encrypted there, and by whom.
set -euo pipefail

encrypted=${1:-}

HS=${HS:-http://matrix.chat.localhost:8008}
MAS=${MAS:-http://account.chat.localhost:8091}
# MAS's admin api is on a port of its own, which development publishes here.
MAS_ADMIN=${MAS_ADMIN:-http://localhost:8092}
CLIENT=${CLIENT:-http://chat.localhost:8090}
AS_TOKEN=omegaweb-dev-as-token
SERVER=chat.localhost
failed=0

# check <what> <expected> <actual>
check() {
    if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: expected $2, got $3"; failed=1; fi
}
# matrix <method> <path> [json] [user to act as]: a call as the application, which prints the body.
matrix() {
    local url="$HS$2"
    [ -n "${4:-}" ] && url="$url?user_id=$(jq -rn --arg user "$4" '$user|@uri')"
    curl -s -X "$1" -H "Authorization: Bearer $AS_TOKEN" -H "Content-Type: application/json" ${3:+-d "$3"} "$url"
}
enc() { jq -rn --arg value "$1" '$value|@uri'; }
megolm='{"algorithm":"m.megolm.v1.aes-sha2"}'
# encryption <room> [user to act as]: the algorithm the room is encrypted with, `none` when it has
# no encryption, and otherwise why the homeserver did not say.
encryption() {
    matrix GET "/_matrix/client/v3/rooms/$(enc "$1")/state/m.room.encryption" '' "${2:-}" \
        | jq -r 'if .errcode == "M_NOT_FOUND" then "none" else .algorithm // .errcode // "no algorithm" end'
}

for _ in $(seq 1 60); do curl -sf "$HS/health" >/dev/null && curl -sf "$MAS_ADMIN/health" >/dev/null && break; sleep 2; done

# The application's two ways in: the application service token above, and MAS's admin api.
admin=$(curl -s -u 0000000000000000000MEGAWEB:omegaweb-dev-mas-client-secret \
    -d 'grant_type=client_credentials&scope=urn:mas:admin' "$MAS_ADMIN/oauth2/token" | jq -r .access_token)
mas() { curl -s -X "$1" -H "Authorization: Bearer $admin" -H "Content-Type: application/json" ${3:+-d "$3"} "$MAS_ADMIN$2"; }

bot="@omegaweb:$SERVER"
matrix POST /_matrix/client/v3/register '{"type":"m.login.application_service","username":"omegaweb","inhibit_login":true}' >/dev/null
check "the application is its bot" "$bot" "$(matrix GET /_matrix/client/v3/account/whoami | jq -r .user_id)"

# Users as MAS makes them at a first sign in, which the application service did not create.
for name in check-kari check-ola; do mas POST /api/admin/v1/users "{\"username\":\"$name\"}" >/dev/null; done
kari="@check-kari:$SERVER"; ola="@check-ola:$SERVER"
check "the application acts as a user MAS made" "$kari" "$(matrix GET /_matrix/client/v3/account/whoami '' "$kari" | jq -r .user_id)"

check "a user creates no space" M_FORBIDDEN \
    "$(matrix POST /_matrix/client/v3/createRoom '{"creation_content":{"type":"m.space"}}' "$kari" | jq -r .errcode)"
space=$(matrix POST /_matrix/client/v3/createRoom '{"name":"Check","preset":"private_chat","room_version":"12",
    "creation_content":{"type":"m.space"},
    "power_level_content_override":{"events":{},"invite":100,"kick":100,"ban":100,"state_default":100}}' | jq -r .room_id)
check "the bot creates a space" '!' "${space:0:1}"

if [ -z "$encrypted" ]; then
    room=$(matrix POST /_matrix/client/v3/createRoom "{\"name\":\"Check\",
        \"initial_state\":[{\"type\":\"m.room.encryption\",\"state_key\":\"\",\"content\":$megolm}]}" "$kari" | jq -r .room_id)
    check "a user creates a room" '!' "${room:0:1}"
    check "which is not encrypted, though it asked to be" none "$(encryption "$room" "$kari")"
    check "and cannot be made so" M_FORBIDDEN \
        "$(matrix PUT "/_matrix/client/v3/rooms/$(enc "$room")/state/m.room.encryption" "$megolm" "$kari" | jq -r .errcode)"
else
    room=$(matrix POST /_matrix/client/v3/createRoom '{"name":"Check"}' "$kari" | jq -r .room_id)
    check "a user creates a room" '!' "${room:0:1}"
    check "which is encrypted, though it did not ask to be" m.megolm.v1.aes-sha2 "$(encryption "$room" "$kari")"
    check "and stays so: its encryption is not set again" M_FORBIDDEN \
        "$(matrix PUT "/_matrix/client/v3/rooms/$(enc "$room")/state/m.room.encryption" '{}' "$kari" | jq -r .errcode)"
    set_by=$(matrix GET "/_matrix/client/v3/rooms/$(enc "$room")/state" '' "$kari" | jq -r '.[] | select(.type == "m.room.encryption") | .event_id')
    check "and not removed" M_FORBIDDEN \
        "$(matrix PUT "/_matrix/client/v3/rooms/$(enc "$room")/redact/$(enc "$set_by")/check-kari" '{}' "$kari" | jq -r .errcode)"
    check "a room that asks for another algorithm gets the one every client reads" m.megolm.v1.aes-sha2 \
        "$(encryption "$(matrix POST /_matrix/client/v3/createRoom '{"initial_state":[{"type":"m.room.encryption","state_key":"",
            "content":{"algorithm":"none"}}]}' "$kari" | jq -r .room_id)" "$kari")"
    check "a message that is not encrypted is refused in it" M_FORBIDDEN \
        "$(matrix PUT "/_matrix/client/v3/rooms/$(enc "$room")/send/m.room.message/check-plain" '{"msgtype":"m.text","body":"Hei"}' "$kari" | jq -r .errcode)"
    check "and one that is, is taken" '$' \
        "$(matrix PUT "/_matrix/client/v3/rooms/$(enc "$room")/send/m.room.encrypted/check-cipher" \
            '{"algorithm":"m.megolm.v1.aes-sha2","ciphertext":"bWFkZSB1cA","session_id":"check"}' "$kari" | jq -r '.event_id[0:1]')"
    replaced=$(matrix POST /_matrix/client/v3/createRoom '{"name":"Byttes ut"}' "$kari" | jq -r .room_id)
    replacing=$(matrix POST "/_matrix/client/v3/rooms/$(enc "$replaced")/upgrade" '{"new_version":"12"}' "$kari" | jq -r .replacement_room)
    check "a room that replaces an encrypted one is encrypted too" m.megolm.v1.aes-sha2 "$(encryption "$replacing" "$kari")"

    # Synapse keeps a room whose creation failed halfway: its creator is in it, and nothing of
    # what was to follow is, the encryption included.
    before=$(matrix GET /_matrix/client/v3/joined_rooms '' "$kari" | jq -c .joined_rooms)
    with_another="{\"initial_state\":[{\"type\":\"m.room.member\",\"state_key\":\"$ola\",\"content\":{\"membership\":\"join\"}}]}"
    check "a room is not made with another user put in it" M_FORBIDDEN \
        "$(matrix POST /_matrix/client/v3/createRoom "$with_another" "$kari" | jq -r .errcode)"
    half=$(matrix GET /_matrix/client/v3/joined_rooms '' "$kari" | jq -r --argjson before "$before" '(.joined_rooms - $before)[0]')
    in_half="/_matrix/client/v3/rooms/$(enc "$half")"
    check "what is left of it is a room that is not encrypted" none "$(encryption "$half" "$kari")"
    check "which nobody is let into" M_FORBIDDEN "$(matrix POST "$in_half/invite" "{\"user_id\":\"$ola\"}" "$kari" | jq -r .errcode)"
    check "and nobody joins" M_FORBIDDEN "$(matrix POST "$in_half/join" '{}' "$ola" | jq -r .errcode)"
    check "it is not encrypted with anything but what every client reads" M_BAD_JSON \
        "$(matrix PUT "$in_half/state/m.room.encryption" '{"algorithm":"none"}' "$kari" | jq -r .errcode)"
    check "or with more said of it than that" M_BAD_JSON \
        "$(matrix PUT "$in_half/state/m.room.encryption" '{"algorithm":"m.megolm.v1.aes-sha2","rotation_period_ms":1000000000000000}' "$kari" | jq -r .errcode)"
    check "its creator encrypts it" '$' "$(matrix PUT "$in_half/state/m.room.encryption" "$megolm" "$kari" | jq -r '.event_id[0:1]')"
    check "and lets another in then" '{}' "$(matrix POST "$in_half/invite" "{\"user_id\":\"$ola\"}" "$kari" | jq -c .)"
fi

check "a user lets another into a room of their own" '{}' \
    "$(matrix POST "/_matrix/client/v3/rooms/$(enc "$room")/invite" "{\"user_id\":\"$ola\"}" "$kari" | jq -c .)"
joined=$(matrix POST /_matrix/client/v3/createRoom '{"name":"Joined"}' "$kari" | jq -r .room_id)
matrix POST "/_matrix/client/v3/rooms/$(enc "$joined")/invite" "{\"user_id\":\"$bot\"}" "$kari" >/dev/null
matrix POST "/_matrix/client/v3/rooms/$(enc "$joined")/join" '{}' >/dev/null
check "but not into a room the application is in, though they made it" M_FORBIDDEN \
    "$(matrix POST "/_matrix/client/v3/rooms/$(enc "$joined")/invite" "{\"user_id\":\"$ola\"}" "$kari" | jq -r .errcode)"
check "where the application lets them in" '{}' \
    "$(matrix POST "/_matrix/client/v3/rooms/$(enc "$joined")/invite" "{\"user_id\":\"$ola\"}" | jq -c .)"

matrix POST "/_matrix/client/v3/rooms/$(enc "$space")/invite" "{\"user_id\":\"$kari\"}" >/dev/null
check "the application puts a user in a space" "$space" \
    "$(matrix POST "/_matrix/client/v3/rooms/$(enc "$space")/join" '{}' "$kari" | jq -r .room_id)"
child="/_matrix/client/v3/rooms/$(enc "$space")/state/m.space.child"
check "a member adds no room to the space" M_FORBIDDEN \
    "$(matrix PUT "$child/$(enc "$room")" "{\"via\":[\"$SERVER\"]}" "$kari" | jq -r .errcode)"
check "lets no one into it" M_FORBIDDEN \
    "$(matrix POST "/_matrix/client/v3/rooms/$(enc "$space")/invite" "{\"user_id\":\"$ola\"}" "$kari" | jq -r .errcode)"
check "and does not rename it" M_FORBIDDEN \
    "$(matrix PUT "/_matrix/client/v3/rooms/$(enc "$space")/state/m.room.name" '{"name":"Mine"}' "$kari" | jq -r .errcode)"

# A room of the space, as the application makes it.
ofspace=$(matrix POST /_matrix/client/v3/createRoom "{\"name\":\"Prat\",\"preset\":\"private_chat\",\"room_version\":\"12\",
    \"initial_state\":[{\"type\":\"m.room.join_rules\",\"state_key\":\"\",
        \"content\":{\"join_rule\":\"restricted\",\"allow\":[{\"type\":\"m.room_membership\",\"room_id\":\"$space\"}]}}],
    \"power_level_content_override\":{\"events\":{\"m.room.pinned_events\":50},\"redact\":50,
        \"invite\":100,\"kick\":100,\"ban\":100,\"state_default\":100}}" | jq -r .room_id)
in_room="/_matrix/client/v3/rooms/$(enc "$ofspace")"
check "the application makes a room of the space" '!' "${ofspace:0:1}"
check "and lists it there" '$' "$(matrix PUT "$child/$(enc "$ofspace")" "{\"via\":[\"$SERVER\"]}" | jq -r '.event_id[0:1]')"
check "a member of the space lets themselves into the room" "$ofspace" "$(matrix POST "$in_room/join" '{}' "$kari" | jq -r .room_id)"
check "and someone outside the space does not" M_FORBIDDEN "$(matrix POST "$in_room/join" '{}' "$ola" | jq -r .errcode)"
check "the room is not encrypted, since the application did not ask for it" none "$(encryption "$ofspace")"

matrix POST "/_matrix/client/v3/rooms/$(enc "$space")/invite" "{\"user_id\":\"$ola\"}" >/dev/null
matrix POST "/_matrix/client/v3/rooms/$(enc "$space")/join" '{}' "$ola" >/dev/null
matrix POST "$in_room/join" '{}' "$ola" >/dev/null
by_kari=$(matrix PUT "$in_room/send/m.room.message/check-kari" '{"msgtype":"m.text","body":"Hei"}' "$kari" | jq -r .event_id)
by_ola=$(matrix PUT "$in_room/send/m.room.message/check-ola" '{"msgtype":"m.text","body":"Hei"}' "$ola" | jq -r .event_id)
check "a member removes nothing another wrote" M_FORBIDDEN \
    "$(matrix PUT "$in_room/redact/$(enc "$by_kari")/check-ola" '{}' "$ola" | jq -r .errcode)"
matrix PUT "$in_room/state/m.room.power_levels" \
    "$(matrix GET "$in_room/state/m.room.power_levels" | jq -c --arg user "$kari" '.users[$user] = 50')" >/dev/null
check "an admin of the space, whom the application gives level 50 in the room, does" '$' \
    "$(matrix PUT "$in_room/redact/$(enc "$by_ola")/check-kari" '{}' "$kari" | jq -r '.event_id[0:1]')"
check "and pins messages" '$' \
    "$(matrix PUT "$in_room/state/m.room.pinned_events" "{\"pinned\":[\"$by_kari\"]}" "$kari" | jq -r '.event_id[0:1]')"
check "but does not rename the room" M_FORBIDDEN \
    "$(matrix PUT "$in_room/state/m.room.name" '{"name":"Mitt"}' "$kari" | jq -r .errcode)"
check "or give anyone a level" M_FORBIDDEN \
    "$(matrix PUT "$in_room/state/m.room.power_levels" \
        "$(matrix GET "$in_room/state/m.room.power_levels" | jq -c --arg user "$ola" '.users[$user] = 50')" "$kari" | jq -r .errcode)"

# A private room of the space, as the application makes it: for those it puts there alone.
private=$(matrix POST /_matrix/client/v3/createRoom '{"name":"Styret","preset":"private_chat","room_version":"12",
    "power_level_content_override":{"events":{"m.room.pinned_events":50},"redact":50,
        "invite":100,"kick":100,"ban":100,"state_default":100}}' | jq -r .room_id)
in_private="/_matrix/client/v3/rooms/$(enc "$private")"
matrix PUT "$child/$(enc "$private")" "{\"via\":[\"$SERVER\"]}" >/dev/null
matrix POST "$in_private/invite" "{\"user_id\":\"$kari\"}" >/dev/null
check "the application puts a member of the space in a private room of it" "$private" \
    "$(matrix POST "$in_private/join" '{}' "$kari" | jq -r .room_id)"
check "a member it did not put there does not get in" M_FORBIDDEN "$(matrix POST "$in_private/join" '{}' "$ola" | jq -r .errcode)"
# listed <room> <user>: whether the user is shown the room among the rooms of the space.
listed() {
    matrix GET "/_matrix/client/v1/rooms/$(enc "$space")/hierarchy" '' "$2" | jq --arg room "$1" '[.rooms[].room_id] | index($room) != null'
}
check "and is not shown it among the rooms of the space" false "$(listed "$private" "$ola")"
check "though they are shown the room every member may enter" true "$(listed "$ofspace" "$ola")"
check "and the one in the private room is shown it" true "$(listed "$private" "$kari")"

# Whether a room of the space is encrypted is the application's to say. The member has the level
# to set it here, so it is the module that refuses.
levels="{\"users\":{\"$kari\":100},\"invite\":100,\"kick\":100,\"ban\":100,\"state_default\":100}"
secret=$(matrix POST /_matrix/client/v3/createRoom "{\"name\":\"Hemmelig\",\"preset\":\"private_chat\",\"room_version\":\"12\",
    \"power_level_content_override\":$levels}" | jq -r .room_id)
in_secret="/_matrix/client/v3/rooms/$(enc "$secret")"
matrix PUT "$child/$(enc "$secret")" "{\"via\":[\"$SERVER\"]}" >/dev/null
matrix POST "$in_secret/invite" "{\"user_id\":\"$kari\"}" >/dev/null
matrix POST "$in_secret/join" '{}' "$kari" >/dev/null
check "a member does not encrypt a room of the space, whatever their level" M_FORBIDDEN \
    "$(matrix PUT "$in_secret/state/m.room.encryption" "$megolm" "$kari" | jq -r .errcode)"
check "under another state key either" M_FORBIDDEN \
    "$(matrix PUT "$in_secret/state/m.room.encryption/other" "$megolm" "$kari" | jq -r .errcode)"
asked=$(matrix POST /_matrix/client/v3/createRoom "{\"name\":\"Hemmelig fra start\",\"preset\":\"private_chat\",\"room_version\":\"12\",
    \"initial_state\":[{\"type\":\"m.room.encryption\",\"state_key\":\"\",\"content\":$megolm}]}" | jq -r .room_id)
if [ -z "$encrypted" ]; then
    check "and neither does the application" M_FORBIDDEN "$(matrix PUT "$in_secret/state/m.room.encryption" "$megolm" | jq -r .errcode)"
    check "a room it asks to have encrypted is made" '!' "${asked:0:1}"
    check "without it" none "$(encryption "$asked")"
else
    check "the application does" '$' "$(matrix PUT "$in_secret/state/m.room.encryption" "$megolm" | jq -r '.event_id[0:1]')"
    check "and the room is encrypted" m.megolm.v1.aes-sha2 "$(encryption "$secret")"
    check "which the application does not set again" M_FORBIDDEN "$(matrix PUT "$in_secret/state/m.room.encryption" '{}' | jq -r .errcode)"
    set_by=$(matrix GET "$in_secret/state" | jq -r '.[] | select(.type == "m.room.encryption") | .event_id')
    check "or remove" M_FORBIDDEN "$(matrix PUT "$in_secret/redact/$(enc "$set_by")/check-bot" '{}' | jq -r .errcode)"
    check "and neither does the member" M_FORBIDDEN "$(matrix PUT "$in_secret/redact/$(enc "$set_by")/check-kari-secret" '{}' "$kari" | jq -r .errcode)"
    check "a room the application asks to have encrypted is so from the start" m.megolm.v1.aes-sha2 "$(encryption "$asked")"
fi

# An invitation the application sent and no longer means: leaving as the invited takes it back.
matrix POST "$in_private/invite" "{\"user_id\":\"$ola\"}" >/dev/null
matrix POST "$in_private/leave" '{}' "$ola" >/dev/null
check "the application takes back an invitation to a private room" M_FORBIDDEN "$(matrix POST "$in_private/join" '{}' "$ola" | jq -r .errcode)"

# A room that is to go is closed first, so that no member of the space gets in while it is emptied.
closing=$(matrix POST /_matrix/client/v3/createRoom "{\"name\":\"Stenges\",\"preset\":\"private_chat\",\"room_version\":\"12\",
    \"initial_state\":[{\"type\":\"m.room.join_rules\",\"state_key\":\"\",
        \"content\":{\"join_rule\":\"restricted\",\"allow\":[{\"type\":\"m.room_membership\",\"room_id\":\"$space\"}]}}],
    \"power_level_content_override\":{\"events\":{},\"invite\":100,\"kick\":100,\"ban\":100,\"state_default\":100}}" | jq -r .room_id)
matrix PUT "/_matrix/client/v3/rooms/$(enc "$closing")/state/m.room.join_rules" '{"join_rule":"invite"}' >/dev/null
check "a room the application has closed lets no member of the space in" M_FORBIDDEN \
    "$(matrix POST "/_matrix/client/v3/rooms/$(enc "$closing")/join" '{}' "$ola" | jq -r .errcode)"

matrix POST "/_matrix/client/v3/rooms/$(enc "$space")/leave" '{}' "$kari" >/dev/null
check "a user taken out of a space does not get back in" M_FORBIDDEN \
    "$(matrix POST "/_matrix/client/v3/rooms/$(enc "$space")/join" '{}' "$kari" | jq -r .errcode)"
matrix POST "$in_room/leave" '{}' "$kari" >/dev/null
check "or into its rooms" M_FORBIDDEN "$(matrix POST "$in_room/join" '{}' "$kari" | jq -r .errcode)"

check "a user does not change their own name" M_FORBIDDEN \
    "$(matrix PUT "/_matrix/client/v3/profile/$(enc "$kari")/displayname" '{"displayname":"Selvvalgt"}' "$kari" | jq -r .errcode)"
# The application sets it through Synapse's admin api, as a user of its own whom MAS gives a token
# with the admin scope. The application service token is refused there.
mas POST /api/admin/v1/users '{"username":"omegaweb-admin"}' >/dev/null
service=$(mas GET /api/admin/v1/users/by-username/omegaweb-admin | jq -r .data.id)
token=$(mas POST /api/admin/v1/personal-sessions "{\"actor_user_id\":\"$service\",\"human_name\":\"check\",
    \"scope\":\"urn:matrix:client:api:* urn:synapse:admin:*\",\"expires_in\":300}" | jq -r .data.attributes.access_token)
check "the application sets a user's name" "Kari Nordmann" \
    "$(curl -s -X PUT -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d '{"displayname":"Kari Nordmann"}' \
        "$HS/_synapse/admin/v2/users/$(enc "$kari")" | jq -r .displayname)"

check "MAS's admin api is not on the port browsers reach" 404 \
    "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $admin" "$MAS/api/admin/v1/users")"
e2ee=$(curl -s "$HS/.well-known/matrix/client" | jq -c '.["io.element.e2ee"]')
if [ -z "$encrypted" ]; then
    check "clients are told that no room is encrypted" true "$(jq .force_disable <<<"$e2ee")"
else
    check "clients are told to encrypt the rooms they make" '{"default":true}' "$e2ee"
fi

check "the client is served, set up for this homeserver" "$SERVER" \
    "$(curl -s "$CLIENT/config.json" | jq -r '.default_server_config["m.homeserver"].server_name')"
check "and may register itself with MAS" true \
    "$(curl -s -H "Content-Type: application/json" -d '{"client_name":"check","client_uri":"http://chat.localhost:8090/",
        "redirect_uris":["http://chat.localhost:8090/"],"grant_types":["authorization_code","refresh_token"],"response_types":["code"],
        "token_endpoint_auth_method":"none","application_type":"web"}' "$MAS/oauth2/registration" | jq 'has("client_id")')"

exit $failed
