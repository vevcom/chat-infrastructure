#!/bin/bash
# Checks the running development stack against what the root README says of it: who may create a
# space, that no room is encrypted, what the application may do, and what a user may not. Run from
# this directory once `docker compose up -d` has settled. It leaves two users, a space and a room
# behind; `docker compose down -v` clears them.
set -euo pipefail

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

for _ in $(seq 1 60); do curl -sf "$HS/health" >/dev/null && curl -sf "$MAS/health" >/dev/null && break; sleep 2; done

# The application's two ways in: the application service token above, and MAS's admin api.
admin=$(curl -s -u 0000000000000000000MEGAWEB:omegaweb-dev-mas-client-secret \
    -d 'grant_type=client_credentials&scope=urn:mas:admin' "$MAS/oauth2/token" | jq -r .access_token)
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
space=$(matrix POST /_matrix/client/v3/createRoom '{"name":"Check","preset":"private_chat","creation_content":{"type":"m.space"},
    "power_level_content_override":{"events":{"m.space.child":50},"invite":100,"kick":100,"ban":100,"state_default":100}}' | jq -r .room_id)
check "the bot creates a space" '!' "${space:0:1}"

room=$(matrix POST /_matrix/client/v3/createRoom '{"name":"Check","initial_state":[{"type":"m.room.encryption","state_key":"",
    "content":{"algorithm":"m.megolm.v1.aes-sha2"}}]}' "$kari" | jq -r .room_id)
check "a user creates a room" '!' "${room:0:1}"
check "which is not encrypted, though it asked to be" 0 \
    "$(matrix GET "/_matrix/client/v3/rooms/$(enc "$room")/state" '' "$kari" | jq '[.[] | select(.type == "m.room.encryption")] | length')"
check "and cannot be made so" M_FORBIDDEN \
    "$(matrix PUT "/_matrix/client/v3/rooms/$(enc "$room")/state/m.room.encryption" '{"algorithm":"m.megolm.v1.aes-sha2"}' "$kari" | jq -r .errcode)"

matrix POST "/_matrix/client/v3/rooms/$(enc "$space")/invite" "{\"user_id\":\"$kari\"}" >/dev/null
check "the application puts a user in a space" "$space" \
    "$(matrix POST "/_matrix/client/v3/rooms/$(enc "$space")/join" '{}' "$kari" | jq -r .room_id)"
child="/_matrix/client/v3/rooms/$(enc "$space")/state/m.space.child/$(enc "$room")"
check "a member adds no room to the space" M_FORBIDDEN "$(matrix PUT "$child" "{\"via\":[\"$SERVER\"]}" "$kari" | jq -r .errcode)"
levels="/_matrix/client/v3/rooms/$(enc "$space")/state/m.room.power_levels"
matrix PUT "$levels" "$(matrix GET "$levels" | jq -c --arg user "$kari" '.users[$user] = 50')" >/dev/null
check "an admin of the space does" '$' "$(matrix PUT "$child" "{\"via\":[\"$SERVER\"]}" "$kari" | jq -r '.event_id[0:1]')"
check "but lets no one in" M_FORBIDDEN \
    "$(matrix POST "/_matrix/client/v3/rooms/$(enc "$space")/invite" "{\"user_id\":\"$ola\"}" "$kari" | jq -r .errcode)"
check "and does not rename it" M_FORBIDDEN \
    "$(matrix PUT "/_matrix/client/v3/rooms/$(enc "$space")/state/m.room.name" '{"name":"Mine"}' "$kari" | jq -r .errcode)"
matrix POST "/_matrix/client/v3/rooms/$(enc "$space")/leave" '{}' "$kari" >/dev/null
check "a user taken out of a space does not get back in" M_FORBIDDEN \
    "$(matrix POST "/_matrix/client/v3/rooms/$(enc "$space")/join" '{}' "$kari" | jq -r .errcode)"

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
check "clients are told that no room is encrypted" true \
    "$(curl -s "$HS/.well-known/matrix/client" | jq '.["io.element.e2ee"].force_disable')"

check "the client is served, set up for this homeserver" "$SERVER" \
    "$(curl -s "$CLIENT/config.json" | jq -r '.default_server_config["m.homeserver"].server_name')"
check "and may register itself with MAS" true \
    "$(curl -s -H "Content-Type: application/json" -d '{"client_name":"check","client_uri":"http://chat.localhost:8090/",
        "redirect_uris":["http://chat.localhost:8090/"],"grant_types":["authorization_code","refresh_token"],"response_types":["code"],
        "token_endpoint_auth_method":"none","application_type":"web"}' "$MAS/oauth2/registration" | jq 'has("client_id")')"

exit $failed
