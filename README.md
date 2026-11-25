# chat-infrastructure

Chat for Sct. Omega Broderskab: a [Matrix](https://matrix.org) homeserver that omegaweb-next
decides the shape of. [Synapse](https://github.com/element-hq/synapse) is the homeserver,
[MAS](https://github.com/element-hq/matrix-authentication-service) signs users in to it through
omegaweb-next, and [Element Web](https://github.com/element-hq/element-web) is the client. In the
shape that runs on the cluster, and in the shape a developer runs next to omegaweb-next.

```
deploy/base/   # Synapse, MAS and Element Web for Kubernetes: the generic shape, which vivat's overlay fills in
dev/           # The same three for development, as a compose file
```

Nothing here names a domain, a certificate or a secret. Those belong to whoever runs an
installation; ours is [vivat](https://github.com/vevcom/vivat), which deploys `deploy/base` for
omega.ntnu.no.

## Words

| Matrix | What it is |
|---|---|
| Space | A group of rooms with a member list of its own. What other chats call a server |
| Room | Where messages are written: a room of a space, a group room or a direct message |
| Homeserver | The whole installation |

## Who decides what

The application, omegaweb-next, decides who has an account and what their name is, which spaces
exist, which rooms each has, who is in it and who administers it. Nobody makes or arranges a room
of a space in the client. Direct messages and group rooms are anyone's to make.

- **Signing in.** MAS takes no password and registers no one. It signs users in through the
  application, which is an OpenID Connect provider, and makes the account at the first sign in.
  The application says in the token what the user is called on the homeserver, as the claim
  `chat_localpart`, and their name. MAS is not told their email.
- **The application service.** Synapse knows the application from a registration file, see
  `deploy/base/synapse/appservice.yaml`. With its token the application acts as its bot, and as
  any user of the homeserver. So it creates a space as the bot, invites a user to it and joins as
  that user, with no invite for them to accept, and takes a user out by leaving as them.
- **The rules.** `deploy/base/synapse/omegaweb_rules.py` is a Synapse module that refuses a space
  anyone but the bot creates, and keeps every room unencrypted: it leaves out the encryption a new
  room asks for and refuses it later. Clients are told so as well, in the well-known file Synapse
  serves, so they do not offer it. It also refuses an invite from anyone but the bot into a room
  the bot is in, which is to say a space or a room of one: who is in those is decided in the
  application.
- **Encryption.** Off, until an installation turns it on, see "Turning encryption on". Then a
  direct message or a group room is always encrypted: the module makes every room a user creates
  so, whether the client asks for it or not. A room of a space is encrypted when the application
  says so: the bot asks for it as it makes the room or sets it later, and the module refuses it
  from anyone else in a room the bot is in. A room that is encrypted stays so: the module refuses
  to have its encryption set again or removed, from the bot too, and refuses a message or a
  sticker in it that is not encrypted. A room the bot is not in that is not encrypted takes no
  new members until it is: Synapse keeps a room whose creation failed halfway, with its creator
  in it and no encryption, and nobody is invited to such a room or joins it. The application
  still hears that someone wrote in an encrypted room, where and when, and reads what the event
  carries beside the encrypted part, such as whom it mentions when the client writes that there.
- **Spaces and their rooms.** The bot creates a space so that nothing in it is anyone else's to
  change, the rooms it lists included. It makes the rooms of a space too, each with a join rule
  that lets the members of the space in without an invite. A private room has no such rule: only
  those the bot puts there are in it, and nobody else is shown it. It gives the space's admins power
  level 50 in those rooms, which removes what others wrote and pins messages, and keeps inviting,
  removing, renaming and the levels to itself.
- **Profiles.** Synapse and MAS let no user change their name, picture or email. The application
  sets them through Synapse's admin api. The application service token is refused there, so it
  signs in to MAS's admin api as a client, and has MAS give a user of its own a token with
  Synapse's admin scope.

`dev/check.sh` checks every line above against a running stack, and `dev/check.sh encrypted`
against one with encryption on.

## What deploy/base is

- **Synapse**, one instance with the media and its signing key on a volume.
- **MAS**, which migrates its own database when it starts.
- **Element Web**, which is static files and a `config.json`.
- **The database**, one CloudNativePG cluster with a database for Synapse and one for MAS. It
  collates as C, which Synapse requires.
- **Three ingresses.** The client's host is also the server name, so `/.well-known/matrix` on it
  goes to Synapse, which answers where the homeserver is and that no room is encrypted. Synapse's
  host publishes what clients use, `/_matrix` and `/_synapse/client`, and not its admin api. MAS's
  host publishes the port browsers reach. MAS's admin api is on a port of its own, 8081, which no
  ingress publishes.

Synapse and MAS each read two config files. The first is the same for every installation and is
the one development runs on: `synapse/homeserver.yaml` and `mas/config.yaml`. The second,
`site.yaml`, is the installation's own, and the ones here hold placeholders.

Synapse reads the application service registration once, when it starts. An init container
renders it first, from `synapse/appservice.yaml` with the two tokens, the server name and where
the application takes events, and makes the signing key the first time.

## What an overlay fills in

- **`synapse-site`**, replaced with a `site.yaml` of the installation's: the server name, where
  clients reach Synapse, the bot's user id for the module, and whether rooms are encrypted.
- **`mas-site`**, replaced with a `site.yaml` of the installation's: where browsers reach MAS, the
  server name, and the application's provider: its issuer, and MAS's own host as the client id.
- **`element-config`**, replaced with a `config.json` naming the homeserver.
- **`synapse-registration`**, with `CHAT_SERVER_NAME`, and `CHAT_APPSERVICE_URL` once the
  application takes events.
- **The hosts of the three ingresses**, with their certificates.
- **Who may reach MAS's admin api**, port 8081 of the `mas` service: the application alone.
- **The `chat-env` secret**, with these keys:

| Key | What it is |
|---|---|
| `SYNAPSE_MACAROON_SECRET`, `SYNAPSE_FORM_SECRET` | Random strings Synapse signs with |
| `MAS_SHARED_SECRET` | A random string Synapse and MAS know each other by |
| `MAS_ENCRYPTION_SECRET` | 32 random bytes as 64 hex characters, which MAS encrypts what it stores with. It can never change |
| `MAS_SIGNING_KEY` | An RSA private key as PEM, which MAS signs its tokens with: `openssl genrsa 2048` |
| `CHAT_AS_TOKEN`, `CHAT_HS_TOKEN` | The application service's two tokens, which the application has too |
| `CHAT_MAS_CLIENT_SECRET` | The application's secret as a client of MAS's admin api, which the application has too |

The database's password is not among them: CloudNativePG makes it.

## Turning encryption on

Two settings in the installation's `site.yaml` for Synapse, which go together:

```yaml
modules:
    - module: omegaweb_rules.OmegawebRules
      config:
          space_creator: "@omegaweb:chat.example.org"
          encryption: true
extra_well_known_client_content:
    io.element.e2ee:
        default: true
```

`encryption` is the module's switch, which is off when it is not there. The second replaces what
`homeserver.yaml` tells clients, that no room is encrypted, so Element asks for encryption in the
rooms it makes. Development's are in `dev/synapse/encrypted.yaml`.

It is turned on once the application's own client reads encrypted rooms, and not before: a client
without encryption makes a direct message, which the module encrypts, and can then neither write
in it nor read it. The application itself writes in no room, as the bot or as a user, and must
not start to in one that may be encrypted. It is not turned off again. A room that was encrypted
meanwhile stays so, and the module would only keep new ones from it.

A direct message or group room made before it was turned on is not encrypted by this. Those in it
go on writing, and it takes no new members until one who has the level for it turns encryption
on, in a client that offers it: by default that is the one who made the room. One the bot is in
is the bot's to let members into and to encrypt, as a room of a space is.

A room Synapse makes itself as anyone but the bot, such as the one for server notices or the one
its admin api moves the members of a closed room to, would be encrypted like any other and take
no message that is not. None is set up here.

## The server name

`server_name` in Synapse's config is the part after the colon in every user id and room id. It can
never change: a homeserver with another name is another, empty homeserver. Where Synapse, MAS and
the client are reached can all be moved.

## No federation

The homeserver talks to no other. Who is in a space is decided in the application, which knows the
users of this homeserver alone.

## How it is consumed

- **Production.** vivat's overlay pulls `deploy/base` at a release tag. Publishing a release here
  opens a pull request on vivat that moves that tag, see `.github/workflows/release.yml`, and
  merging it is the deploy. Nothing is built: the three run from their own images, pinned in
  `deploy/base`. The pull request is opened with the same GitHub App as omegaweb-next's, so this
  repo needs the variable `DEPLOY_APP_ID` and the secret `DEPLOY_APP_PRIVATE_KEY` too.
- **Development.** omegaweb-next has this repo as a submodule and includes `dev/compose.yaml` in
  its own dev stack with `npm run docker:dev -- --chat`. The version of the chat there is the
  submodule's commit.
