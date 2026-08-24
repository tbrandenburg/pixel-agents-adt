# AGENTS.md

How to build and run this image, and what to actually consider before you do.

## What this is

A single, portable `Dockerfile` that combines two independent projects in
one container, sharing one `$HOME` so they discover each other with zero
manual wiring:

- **[pixel-agents](https://github.com/tbrandenburg/pixel-agents)** —
  standalone webview server (port `3100`).
- **[node-red-agents](https://github.com/tbrandenburg/node-red-agents)** —
  Node-RED instance running the `demo/` **Agentic Development Team** (ADT)
  flow (port `1881`).

The Dockerfile is self-contained: every source tree is fetched via
`git clone` *inside* the build (no local build-context dependency), so this
single file can be copied anywhere and built with an empty/throwaway
context:

```sh
mkdir /tmp/ctx && cd /tmp/ctx
docker build -f /path/to/Dockerfile -t pixel-agents-adt .
```

Override `--build-arg PIXEL_AGENTS_REPO`/`_REF` and
`NODE_RED_AGENTS_REPO`/`_REF` to point at forks/branches other than the
defaults (`tbrandenburg/pixel-agents`, `tbrandenburg/node-red-agents`, both
`main`).

## Makefile targets

`make help` lists them; the shortlist: `build` (docker build), `run` (start
container with the flags below), `stop` (remove container), `logs` (follow
container logs), `clean` (stop + remove image).

`build` accepts an optional `CACERT=/path/to/ca-bundle.pem` if your network
sits behind a TLS-intercepting proxy (e.g. Netskope, or a corporate MITM
root CA) — without it, `apt`/`curl`/`npm` inside the build fail with
`SELF_SIGNED_CERT_IN_CHAIN`. The cert is passed as a BuildKit secret (never
baked into image layers) and merged into both the OS trust store and
Node's own CA list (`NODE_EXTRA_CA_CERTS`, since `npm` ignores the OS store
by default) in every stage that touches the network:

```sh
make build CACERT=/path/to/corporate-ca-bundle.pem
```

Plain `docker build` also supports this directly:

```sh
DOCKER_BUILDKIT=1 docker build --secret id=cacert,src=/path/to/ca.pem -t pixel-agents-adt .
```

## Building

```sh
docker build -t pixel-agents-adt .
```

Multi-stage: `pixel-builder` (clone + `npm run build`), `nodered-builder`
(clone + `npm install` for the root workspace and the `demo/` userDir, plus
a build-time patch — see "The srt patch" below), `runtime` (installs `gh`,
`opencode`, `bubblewrap`, `ripgrep`, `socat`, and
`@anthropic-ai/sandbox-runtime`, then copies both built trees in).

## Running

```sh
docker run -d --name pixel-agents-adt \
  --cap-add=SYS_ADMIN --cap-add=NET_ADMIN \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  -p 3100:3100 -p 1881:1881 \
  -e GH_TOKEN="$(gh auth token)" \
  pixel-agents-adt
```

Both processes are backgrounded by one entrypoint and share `$HOME`, so
node-red-agents' ADT flow discovers pixel-agents by reading
`~/.pixel-agents/server.json` (port + auth token), exactly like it does on a
bare-metal `make demo` + `start-web-server.sh` setup. If either process
exits, the entrypoint kills the other and the container exits non-zero —
they're meant to live and die together, not be independently restarted.

### Why those specific flags

`node-red-agents`' `agent` node runs real `opencode` executions through
Anthropic's `srt` (sandbox-runtime), which wraps commands in
[bubblewrap](https://github.com/containers/bubblewrap) — its own nested
sandbox, built on user/mount/PID/network namespaces. Running that *inside*
an already-containerized process needs:

- `--cap-add=SYS_ADMIN` + `--cap-add=NET_ADMIN` — bubblewrap needs to create
  namespaces and bring up a loopback interface inside them.
- `--security-opt seccomp=unconfined` — Docker's default seccomp profile
  blocks `mount`/`pivot_root`, which bubblewrap needs even with the above
  capabilities.
- `--security-opt apparmor=unconfined` — Docker's default AppArmor profile
  blocks the same mount operations independently of seccomp.

This is a **meaningfully wider attack surface** than a normal container.
Full `--privileged` also works but is broader than necessary — the four
flags above are the minimal set found by narrowing down from `--privileged`
one restriction at a time. Fine for your own machine; think twice before
running this anywhere less trusted.

### Credentials — what's needed and what is deliberately *not* baked in

- **`GH_TOKEN`** (env var only, not a file): `gh`'s keyring-backed auth
  (the default on most Linux desktops) does not survive a headless
  container, so `gh` needs a plain token instead. Pass
  `$(gh auth token)` from a host where you're already logged in.
- **No `opencode` credentials of any kind are mounted or baked into this
  image.** The ADT flow's default model is `opencode/big-pickle`, a free
  [OpenCode Zen](https://opencode.ai/docs/zen) model that needs no API key
  or auth file at all — there is nothing to inject. If you change the
  model to one that needs auth, you'll need to add your own credential
  handling; **never** bake a host's `~/.local/share/opencode/auth.json`
  into an image or a public repo.

### The srt patch

`srt`'s default configuration assumes a privileged host and fails inside an
unprivileged container in several ways this image works around, in order:

1. `enableWeakerNestedSandbox: true` — srt's own upstream source documents
   this setting as existing specifically "for Docker environments"; without
   it, bubblewrap can't mount a fresh `/proc` for its isolated PID
   namespace.
2. Pre-created `~/.local/share/opencode`, `~/.cache`, `~/.config`,
   `~/.local/state/opencode`, `~/.opencode` — srt's write-allowlist only
   allow-lists the exact leaf directories the flow declares; in a brand-new
   container those parents don't exist yet, so `opencode`'s own `mkdir -p`
   recursion into a non-allowed parent fails `EROFS` inside the sandbox.
   Fixed by pre-creating them (outside the sandbox) and widening the
   allow-write list to match.
3. `models.opencode.ai` added to the network allowlist — domain matching in
   srt is exact-host, not wildcard; the model's real API host is a
   subdomain of the already-allowed `opencode.ai`.

All three are applied by patching the ADT flow's `adt-run-agent` node's
`srtAdvancedJson` field at build time (see the `RUN node -e '...'` step in
the Dockerfile) — no hand-edits to `demo/flows.json` are needed to rebuild
from a fresh clone.

### Read-only guarantee

The ADT flow only ever operates in local, per-task git worktrees and never
pushes, comments, or opens anything against the real remote — verified live
against `github.com/tbrandenburg/node-red-agents` with no `adt/*` branches
pushed and no bot comments left behind. Point this at any repo you have
read access to; it will not write to it.

## Known non-goals / not fixed here

- `gh run view --log` can fail with a network-allowlist `Forbidden` on
  newer `gh` CLI versions that redirect log fetches to
  `results-receiver.actions.githubusercontent.com` instead of serving them
  directly from `api.github.com`. Non-fatal — the flow catches the error
  and moves on; add that host to `adt-run-agent`'s `srtAllowedDomains` if
  you need Actions log fetching to succeed.
- This image is a demo/PoC, not a hardened deployment artifact. See "Why
  those specific flags" above before running it anywhere multi-tenant.

## License

[MIT](./LICENSE)
