# pixel-agents-adt 🤖🏢

**Watch your AI coding agents work — literally.**

This is a one-command demo box that puts a live, browser-based pixel-art
office ([pixel-agents](https://github.com/tbrandenburg/pixel-agents)) right
next to a real multi-agent orchestration flow
([node-red-agents](https://github.com/tbrandenburg/node-red-agents)'s
**Agentic Development Team**), wired together so every agent your flow
dispatches walks into the room the moment it starts working.

Point it at any public GitHub repo, hit **Start**, and watch sandboxed
`opencode` agents pick up open issues, pull requests, and Actions runs —
each one rendered as its own character, live, in the office — while the
underlying automation stays fully read-only (no commits, no pushed
branches, no comments).

One `docker build` + `docker run`. No manual glue code. No accounts beyond
GitHub. The default model needs no API key at all.

## Quick start

```sh
make build
make run
```

Or without `make`:

```sh
docker build -t pixel-agents-adt .

docker run -d --name pixel-agents-adt \
  --cap-add=SYS_ADMIN --cap-add=NET_ADMIN \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  -p 3100:3100 -p 1881:1881 \
  -e GH_TOKEN="$(gh auth token)" \
  pixel-agents-adt
```

Then open:

- **`http://localhost:3100`** — the pixel-art office (watch agents appear)
- **`http://localhost:1881/dashboard/adt`** — the control panel (point it at
  a repo, hit Start)

See [AGENTS.md](./AGENTS.md) for exactly what those flags do, why they're
needed, and what to consider before running this anywhere but your own
machine.

## License

[MIT](./LICENSE)
