# chat-infrastructure

Chat for Sct. Omega Broderskab: a [Matrix](https://matrix.org) homeserver that omegaweb-next
decides the shape of. [Synapse](https://github.com/element-hq/synapse) is the homeserver,
[MAS](https://github.com/element-hq/matrix-authentication-service) signs users in to it through
omegaweb-next, and [Element Web](https://github.com/element-hq/element-web) is the client.

```
synapse/   # The Synapse module with the rules Synapse has no setting for
dev/       # The three for development, as a compose file
```

The shape that runs on the cluster, `deploy/base`, is not here yet.

## Words

| Matrix | What it is |
|---|---|
| Space | A group of rooms with a member list of its own. What other chats call a server |
| Room | Where messages are written: a room of a space, a group room or a direct message |
| Homeserver | The whole installation |

## Who decides what

The application, omegaweb-next, decides who has an account and what their name is, which spaces
exist, who is in each and who administers it. The rooms of a space are made and arranged by its
admins in the client. Direct messages and group rooms are anyone's to make.

- **Signing in.** MAS takes no password and registers no one. It signs users in through the
  application, which is an OpenID Connect provider, and makes the account at the first sign in.
  The application says in the token what the user is called on the homeserver, as the claim
  `chat_localpart`, and their name. MAS is not told their email.
- **The application service.** Synapse knows the application from a registration file, see
  `dev/synapse/appservice.yaml`. With its token the application acts as its bot, and as any user
  of the homeserver. So it creates a space as the bot, invites a user to it and joins as that user,
  with no invite for them to accept, and takes a user out by leaving as them.
- **The rules.** `synapse/omegaweb_rules.py` is a Synapse module that refuses a space anyone but
  the bot creates, and keeps every room unencrypted: it leaves out the encryption a new room asks
  for and refuses it later.
- **Admins of a space.** The bot creates a space so that power level 50 adds and removes its rooms
  and nothing else. It gives the space's admins that level, and keeps inviting, removing and
  renaming to itself.
- **Profiles.** Synapse and MAS let no user change their name, picture or email. The application
  sets them through Synapse's admin api. The application service token is refused there, so it
  signs in to MAS's admin api as a client, and has MAS give a user of its own a token with
  Synapse's admin scope.

`dev/check.sh` checks every line above against a running stack.

## The server name

`server_name` in Synapse's config is the part after the colon in every user id and room id. It can
never change: a homeserver with another name is another, empty homeserver. Where Synapse, MAS and
the client are reached can all be moved.

## No federation

The homeserver talks to no other. Who is in a space is decided in the application, which knows the
users of this homeserver alone.
