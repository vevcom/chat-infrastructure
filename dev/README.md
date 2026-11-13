# Chat in development

Synapse, MAS and Element Web, on plain http, with a Postgres of their own. They run on the config
of `../deploy/base`, which is production's, with the site files of this directory beside it:
`synapse/site.yaml` and `mas/site.yaml`.

```bash
docker compose up -d
./check.sh
```

| | Address |
|---|---|
| The client | http://chat.localhost:8090 |
| Synapse | http://matrix.chat.localhost:8008 |
| MAS | http://account.chat.localhost:8091 |
| MAS's admin api | http://localhost:8092 |

Browsers resolve every name under `localhost` to the machine itself. The server name is
`chat.localhost`, so a user is `@<username>:chat.localhost`.

Signing in goes through omegaweb-next, which is an OpenID Connect provider on
`http://auth.localhost:3000` when it runs with the `sites.json` of its example. The client sends
you to MAS, MAS sends you there, and you come back as `@<username>:chat.localhost`. The first time,
MAS shows the Matrix id and the name the account gets and asks you to confirm. MAS reaches the
provider through `auth.localhost`, which the compose file points at the machine. Without
omegaweb-next running nobody signs in; `check.sh` makes its users through MAS's admin api and acts
as them through the application service.

## What is fixed and what is made

The values that are secrets in production are fixed here, in the environment of the `chat-keys`
service in `compose.yaml`: the tokens of the application service, the secret Synapse and MAS
share, and the secret of the application as a client of MAS's admin api. That service writes them
to the files production gets from its secret store, renders the application service registration,
and makes what is not fixed: Synapse's signing key and the keys MAS encrypts and signs with. Those
are made on the first start and kept on volumes, so a restart keeps every session.
`docker compose down -v` clears them with everything else.

## How an application connects

- To Synapse at `http://synapse:8008` over the compose network, with the `CHAT_AS_TOKEN` of
  `compose.yaml`.
- To MAS's admin api at `http://mas:8081`, as the client in `mas/site.yaml`, with the
  `client_credentials` grant and the scope `urn:mas:admin`. The token is asked for on the same
  port, at `/oauth2/token`.
- As the provider MAS signs users in through, see `upstream_oauth2` in `mas/site.yaml`. MAS is a
  client named by its host, `account.chat.localhost`, with PKCE and no secret, and takes the code
  back at `/upstream/callback/<the provider's id in the config>`. It asks for the scopes `openid`,
  `profile` and `chat`, and makes the account by the claims `chat_localpart` and `name`.


## On an Apple M4

The Synapse image crashed with "Illegal instruction" on an M4 Pro under Docker Desktop 25.0.2,
which is older than the chip, as soon as it used OpenSSL. The compose file sets `OPENSSL_armcap=0`
for Synapse, which stops OpenSSL from probing what the processor can do and so from using what the
virtual machine does not carry. It does nothing on a processor that is not ARM. Whether a current
Docker Desktop needs it has not been tried.
